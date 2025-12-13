#!/usr/bin/env bash

set -e

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 脚本版本
VERSION="1.0.0"

# 全局变量
DEPLOY_DIR=""
OS_TYPE=""
CURRENT_TAG=""
TARGET_TAG=""
CURRENT_VERSION=""
NEW_VERSION=""
BACKUP_CREATED=false
BACKUP_DIR=""

print_header() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║            Claude Code Hub - Upgrade Assistant                 ║"
    echo "║                      Version ${VERSION}                            ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    else
        log_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    log_info "Detected OS: $OS_TYPE"
}

find_deployment() {
    log_info "正在搜索 Claude Code Hub 部署目录..."
    
    # 获取脚本所在目录
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script_parent_dir="$(dirname "$script_dir")"
    
    # 检查常见的部署位置
    local possible_dirs=(
        "$script_parent_dir"
        "$(pwd)"
        "/www/compose/claude-code-hub"
        "$HOME/Applications/claude-code-hub"
        "$HOME/claude-code-hub"
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [[ -f "$dir/docker-compose.yaml" ]] || [[ -f "$dir/docker-compose.yml" ]]; then
            # 验证是否为 Claude Code Hub 部署
            if grep -q "claude-code-hub" "$dir/docker-compose.yaml" 2>/dev/null || \
               grep -q "claude-code-hub" "$dir/docker-compose.yml" 2>/dev/null; then
                DEPLOY_DIR="$dir"
                log_success "找到部署目录: $DEPLOY_DIR"
                return 0
            fi
        fi
    done
    
    # 如果未找到，询问用户
    echo ""
    echo -e "${YELLOW}未能自动找到 Claude Code Hub 部署目录。${NC}"
    read -p "请输入部署目录路径: " user_dir
    
    if [[ -d "$user_dir" ]] && [[ -f "$user_dir/docker-compose.yaml" || -f "$user_dir/docker-compose.yml" ]]; then
        DEPLOY_DIR="$user_dir"
        log_success "使用部署目录: $DEPLOY_DIR"
        return 0
    else
        log_error "无效目录或未找到 docker-compose.yaml"
        exit 1
    fi
}

get_current_version() {
    log_info "正在检测当前版本..."
    
    cd "$DEPLOY_DIR"
    
    # 从 docker-compose.yaml 获取当前镜像标签
    CURRENT_TAG=$(grep -E "image:.*claude-code-hub:" docker-compose.yaml 2>/dev/null | sed -E 's/.*:(latest|dev|[0-9.]+).*/\1/' | head -n1)
    
    if [[ -z "$CURRENT_TAG" ]]; then
        CURRENT_TAG="unknown"
    fi
    
    log_info "当前镜像标签: $CURRENT_TAG"
    
    # 尝试获取正在运行的容器镜像和版本
    local app_container=$(docker ps --filter "name=claude-code-hub-app" --format "{{.Names}}" | head -n1)
    
    if [[ -n "$app_container" ]]; then
        local running_image=$(docker inspect --format='{{.Config.Image}}' "$app_container" 2>/dev/null)
        log_info "运行中的镜像: $running_image"
        
        # 从容器中获取版本号（如果存在）
        CURRENT_VERSION=$(docker exec "$app_container" cat /app/VERSION 2>/dev/null || echo "")
        
        if [[ -z "$CURRENT_VERSION" ]]; then
            # 如果获取不到版本号，尝试获取镜像创建日期
            local image_created=$(docker inspect --format='{{.Created}}' "$running_image" 2>/dev/null | cut -d'T' -f1)
            if [[ -n "$image_created" ]]; then
                CURRENT_VERSION="build: $image_created"
            else
                CURRENT_VERSION="unknown"
            fi
        fi
        
        log_info "当前版本: $CURRENT_VERSION"
    else
        CURRENT_VERSION="(容器未运行)"
        log_warning "应用容器未运行"
    fi
}

select_target_version() {
    echo ""
    echo -e "${BLUE}请选择目标版本:${NC}"
    echo -e "  ${GREEN}1)${NC} latest  (稳定版 - 推荐用于生产环境)"
    echo -e "  ${YELLOW}2)${NC} dev     (开发版 - 包含最新功能，用于测试)"
    if [[ "$CURRENT_TAG" == "dev" ]]; then
        echo -e "  ${CYAN}3)${NC} 切换到 latest (从开发版降级到稳定版)"
    fi
    echo ""
    
    local choice
    while true; do
        read -p "请输入选择 [1]: " choice
        choice=${choice:-1}
        
        case $choice in
            1)
                TARGET_TAG="latest"
                log_success "已选择目标版本: latest (稳定版)"
                break
                ;;
            2)
                TARGET_TAG="dev"
                log_success "已选择目标版本: dev (开发版)"
                break
                ;;
            3)
                if [[ "$CURRENT_TAG" == "dev" ]]; then
                    TARGET_TAG="latest"
                    log_success "已选择从 dev 切换到 latest (稳定版)"
                    break
                else
                    log_error "无效选择，请输入 1 或 2。"
                fi
                ;;
            *)
                log_error "无效选择，请输入 1 或 2。"
                ;;
        esac
    done
}

check_for_updates() {
    log_info "正在检查更新..."
    
    cd "$DEPLOY_DIR"
    
    # 拉取最新镜像以检查更新
    local target_image="ghcr.io/ding113/claude-code-hub:${TARGET_TAG}"
    
    log_info "正在拉取镜像: $target_image"
    
    if docker pull "$target_image" 2>&1; then
        log_success "镜像拉取成功"
        
        # 比较镜像摘要
        local current_digest=$(docker images --digests --format "{{.Digest}}" "ghcr.io/ding113/claude-code-hub:${CURRENT_TAG}" 2>/dev/null | head -n1)
        local new_digest=$(docker images --digests --format "{{.Digest}}" "$target_image" 2>/dev/null | head -n1)
        
        if [[ "$current_digest" == "$new_digest" ]] && [[ "$CURRENT_TAG" == "$TARGET_TAG" ]]; then
            log_info "您已经在运行 $TARGET_TAG 的最新版本"
            read -p "是否仍要重启服务？(Y/n): " restart
            if [[ "$restart" =~ ^[Nn]$ ]]; then
                log_info "升级已取消"
                exit 0
            fi
        else
            log_success "发现新版本！"
        fi
    else
        log_error "镜像拉取失败，请检查网络连接。"
        exit 1
    fi
}

backup_data() {
    log_step "正在创建备份..."
    
    cd "$DEPLOY_DIR"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="${DEPLOY_DIR}/backups/${timestamp}"
    
    mkdir -p "$BACKUP_DIR"
    
    # 备份 .env 文件
    if [[ -f ".env" ]]; then
        cp ".env" "$BACKUP_DIR/.env"
        log_info "已备份 .env"
    fi
    
    # 备份 docker-compose.yaml
    if [[ -f "docker-compose.yaml" ]]; then
        cp "docker-compose.yaml" "$BACKUP_DIR/docker-compose.yaml"
        log_info "已备份 docker-compose.yaml"
    fi
    
    # 注意：此处不备份数据库，因为数据库数据持久化在 ./data/ 目录
    # 如需完整数据库备份，请单独使用 pg_dump
    
    BACKUP_CREATED=true
    log_success "备份已创建: $BACKUP_DIR"
    
    # 仅保留最近 5 个备份
    local backup_count=$(ls -1d "${DEPLOY_DIR}/backups/"*/ 2>/dev/null | wc -l)
    if [[ $backup_count -gt 5 ]]; then
        log_info "正在清理旧备份（保留最近 5 个）..."
        ls -1dt "${DEPLOY_DIR}/backups/"*/ | tail -n +6 | xargs rm -rf
    fi
}

update_compose_image_tag() {
    log_step "正在更新 docker-compose.yaml 镜像标签..."
    
    cd "$DEPLOY_DIR"
    
    # 更新 docker-compose.yaml 中的镜像标签
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' "s|image: ghcr.io/ding113/claude-code-hub:.*|image: ghcr.io/ding113/claude-code-hub:${TARGET_TAG}|g" docker-compose.yaml
    else
        sed -i "s|image: ghcr.io/ding113/claude-code-hub:.*|image: ghcr.io/ding113/claude-code-hub:${TARGET_TAG}|g" docker-compose.yaml
    fi
    
    log_success "镜像标签已更新为: $TARGET_TAG"
}

stop_services() {
    log_step "正在停止服务..."
    
    cd "$DEPLOY_DIR"
    
    if docker compose version &> /dev/null; then
        docker compose stop app
    else
        docker-compose stop app
    fi
    
    log_success "应用服务已停止"
}

start_services() {
    log_step "正在启动服务..."
    
    cd "$DEPLOY_DIR"
    
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    log_success "服务已启动"
}

wait_for_health() {
    log_step "正在等待服务健康检查..."
    
    cd "$DEPLOY_DIR"
    
    local max_attempts=24  # 2 分钟
    local attempt=0
    
    # 查找应用容器名称（可能带有后缀）
    local app_container=$(docker ps --filter "name=claude-code-hub-app" --format "{{.Names}}" | head -n1)
    
    if [[ -z "$app_container" ]]; then
        log_warning "未找到应用容器"
        return 1
    fi
    
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        local app_health=$(docker inspect --format='{{.State.Health.Status}}' "$app_container" 2>/dev/null || echo "unknown")
        
        if [[ "$app_health" == "healthy" ]]; then
            echo ""
            log_success "应用服务健康检查通过！"
            
            # 升级后获取新版本号
            NEW_VERSION=$(docker exec "$app_container" cat /app/VERSION 2>/dev/null || echo "")
            if [[ -z "$NEW_VERSION" ]]; then
                local new_image=$(docker inspect --format='{{.Config.Image}}' "$app_container" 2>/dev/null)
                local image_created=$(docker inspect --format='{{.Created}}' "$new_image" 2>/dev/null | cut -d'T' -f1)
                NEW_VERSION="构建日期: ${image_created:-未知}"
            fi
            log_info "新版本: $NEW_VERSION"
            
            return 0
        elif [[ "$app_health" == "unhealthy" ]]; then
            echo ""
            log_error "应用服务健康检查失败"
            return 1
        fi
        
        echo -ne "\r${BLUE}[INFO]${NC} 健康状态: $app_health (尝试 $attempt/$max_attempts)    "
        sleep 5
    done
    
    echo ""
    log_warning "服务在 2 分钟内未能通过健康检查"
    return 1
}

cleanup_old_images() {
    log_step "正在清理旧镜像..."
    
    # 删除悬空镜像
    docker image prune -f > /dev/null 2>&1 || true
    
    # 删除旧的 claude-code-hub 镜像（保留当前版本）
    docker images "ghcr.io/ding113/claude-code-hub" --format "{{.ID}} {{.Tag}}" | \
        grep -v "$TARGET_TAG" | \
        awk '{print $1}' | \
        xargs -r docker rmi 2>/dev/null || true
    
    log_success "清理完成"
}

rollback() {
    log_error "升级失败！正在尝试回滚..."
    
    if [[ "$BACKUP_CREATED" == true ]] && [[ -d "$BACKUP_DIR" ]]; then
        cd "$DEPLOY_DIR"
        
        # 恢复 docker-compose.yaml
        if [[ -f "$BACKUP_DIR/docker-compose.yaml" ]]; then
            cp "$BACKUP_DIR/docker-compose.yaml" "docker-compose.yaml"
        fi
        
        # 使用旧配置重启
        if docker compose version &> /dev/null; then
            docker compose up -d
        else
            docker-compose up -d
        fi
        
        log_warning "已回滚到之前的版本"
        log_info "备份文件位于: $BACKUP_DIR"
    else
        log_error "没有可用的备份用于回滚"
        log_info "请手动从备份中恢复"
    fi
}

print_success_message() {
    local app_port=$(grep -E "APP_PORT" "$DEPLOY_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -n1)
    app_port=${app_port:-23000}
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                ║${NC}"
    echo -e "${GREEN}║          🎉 Claude Code Hub Upgraded Successfully! 🎉         ║${NC}"
    echo -e "${GREEN}║                                                                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}📍 部署目录:${NC}"
    echo -e "   $DEPLOY_DIR"
    echo ""
    echo -e "${BLUE}🏷️  版本变更:${NC}"
    echo -e "   ┌─────────────┬────────────────────────────────┐"
    echo -e "   │  升级前     │ ${YELLOW}${CURRENT_TAG}${NC} (${CURRENT_VERSION})"
    echo -e "   │  升级后     │ ${GREEN}${TARGET_TAG}${NC} (${NEW_VERSION:-检测中...})"
    echo -e "   └─────────────┴────────────────────────────────┘"
    echo ""
    echo -e "${BLUE}🌐 访问地址:${NC}"
    echo -e "   ${GREEN}http://localhost:${app_port}${NC}"
    echo ""
    echo -e "${BLUE}🔧 常用命令:${NC}"
    echo -e "   查看日志:   ${YELLOW}cd $DEPLOY_DIR && docker compose logs -f app${NC}"
    echo -e "   检查状态:   ${YELLOW}cd $DEPLOY_DIR && docker compose ps${NC}"
    echo -e "   回滚版本:   ${YELLOW}从 $BACKUP_DIR 恢复${NC}"
    echo ""
    echo -e "${BLUE}📋 更新日志:${NC}"
    echo -e "   ${GREEN}https://github.com/ding113/claude-code-hub/blob/main/CHANGELOG.md${NC}"
    echo ""
}

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "升级 Claude Code Hub 到最新版本。"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo "  -d, --dir PATH      指定部署目录"
    echo "  -t, --tag TAG       指定目标镜像标签 (latest, dev)"
    echo "  -y, --yes           跳过确认提示"
    echo "  --no-backup         跳过备份创建"
    echo "  --no-cleanup        跳过旧镜像清理"
    echo ""
    echo "示例:"
    echo "  $0                              # 交互式升级"
    echo "  $0 -d /path/to/deploy -t latest # 在指定目录升级到 latest"
    echo "  $0 -t dev -y                    # 升级到 dev 且跳过确认"
    echo ""
}

# 解析命令行参数
SKIP_CONFIRM=false
SKIP_BACKUP=false
SKIP_CLEANUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--dir)
            DEPLOY_DIR="$2"
            shift 2
            ;;
        -t|--tag)
            TARGET_TAG="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --no-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --no-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

main() {
    print_header
    
    detect_os
    
    # 查找部署目录
    if [[ -z "$DEPLOY_DIR" ]]; then
        find_deployment
    else
        if [[ ! -d "$DEPLOY_DIR" ]]; then
            log_error "指定的目录不存在: $DEPLOY_DIR"
            exit 1
        fi
        log_info "使用指定目录: $DEPLOY_DIR"
    fi
    
    # 获取当前版本
    get_current_version
    
    # 如果未指定目标版本，则让用户选择
    if [[ -z "$TARGET_TAG" ]]; then
        select_target_version
    else
        log_info "使用指定的目标标签: $TARGET_TAG"
    fi
    
    # 检查更新
    check_for_updates
    
    # 确认升级
    if [[ "$SKIP_CONFIRM" != true ]]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                        升级摘要                                ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BLUE}📍 部署目录:${NC}"
        echo -e "   $DEPLOY_DIR"
        echo ""
        echo -e "${BLUE}📦 当前版本:${NC}"
        echo -e "   镜像标签: ${YELLOW}${CURRENT_TAG}${NC}"
        echo -e "   版本号:   ${YELLOW}${CURRENT_VERSION}${NC}"
        echo ""
        echo -e "${BLUE}🚀 目标版本:${NC}"
        echo -e "   镜像标签: ${GREEN}${TARGET_TAG}${NC}"
        echo ""
        echo -e "${BLUE}📋 升级步骤:${NC}"
        echo -e "   1. 创建 .env 和 docker-compose.yaml 的备份"
        echo -e "   2. 从 GitHub Container Registry 拉取新镜像"
        echo -e "   3. 停止应用服务"
        echo -e "   4. 更新 docker-compose.yaml 镜像标签"
        echo -e "   5. 启动服务"
        echo -e "   6. 等待健康检查"
        echo -e "   7. 清理旧镜像"
        echo ""
        read -p "是否继续？(Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_info "升级已取消"
            exit 0
        fi
    fi
    
    # 创建备份
    if [[ "$SKIP_BACKUP" != true ]]; then
        backup_data
    fi
    
    # 执行升级
    trap rollback ERR
    
    stop_services
    update_compose_image_tag
    start_services
    
    if wait_for_health; then
        trap - ERR
        
        # 清理旧镜像
        if [[ "$SKIP_CLEANUP" != true ]]; then
            cleanup_old_images
        fi
        
        print_success_message
    else
        log_warning "升级已完成，但健康检查未通过"
        log_info "服务可能仍在启动中，请检查:"
        echo -e "   ${YELLOW}cd $DEPLOY_DIR && docker compose logs -f app${NC}"
        
        trap - ERR
        print_success_message
    fi
}

main "$@"
