#!/bin/bash
# ================================================================
# EasyTier Cross-Platform Interactive Script (Linux / macOS / Docker)
# Supports: Config inheritance / Multi-peer / Auto-start / Version detection
#           Synology NAS detection / Storage pool path adaptation
#           Multi-Mirror Fallback / Virtual Subnet Proxy (1:1 NAT)
#           UI Enhanced & IPTABLES Forwarding Patched (Full macOS Support)
# ================================================================
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
success() { echo -e "${BOLD}${GREEN}✓ $1${RESET}"; }

if [ "$(id -u)" -ne 0 ]; then
    error "Please run with root or sudo! / 请使用 root 或 sudo 运行此脚本！"
    exit 1
fi

# ================================================================
# 高可用 Github 镜像轮询池 (官方源优先)
# ================================================================
RELEASE_BASES=(
    "https://github.com/EasyTier/EasyTier/releases"
    "https://kkgithub.com/EasyTier/EasyTier/releases"
    "https://ghproxy.net/https://github.com/EasyTier/EasyTier/releases"
    "https://github.moeyy.xyz/https://github.com/EasyTier/EasyTier/releases"
)

is_synology() {
    [ -f /etc/synoinfo.conf ] && uname -a 2>/dev/null | grep -qi synology
}

get_synology_docker_dir() {
    local vol
    vol=$(grep -oP 'volume_name="\K[^"]+' /etc/synoinfo.conf 2>/dev/null | head -1 || true)
    echo "/${vol:-volume1}/docker"
}

# ================================================================
# 环境选择
# ================================================================
echo -e "\n${BOLD}${BLUE}=====================================${RESET}"
echo -e "${BOLD}${BLUE}       EasyTier 跨平台部署向导       ${RESET}"
echo -e "${BOLD}${BLUE}=====================================${RESET}"
echo " 1. Linux  原生 (Systemd, 推荐常见 Linux 服务器)"
echo " 2. macOS  原生 (Launchd, Mac desktop or node)"
echo " 3. Docker 容器 (Compose, 适合 NAS 或 OpenWrt 等环境)"
printf "请选择 / Select environment [1/2/3] (默认/default: 1): "
read -r env_input
env_input=${env_input:-1}

case "$env_input" in
    1) ENV_TYPE="linux"  ;;
    2) ENV_TYPE="macos"  ;;
    3) ENV_TYPE="docker" ;;
    *) ENV_TYPE="linux"  ;;
esac

info "Selected environment: ${CYAN}${ENV_TYPE}${RESET}"

if [ "$ENV_TYPE" = "macos" ]; then
    CONF_DIR="/usr/local/etc/easytier"
elif [ "$ENV_TYPE" = "docker" ]; then
    CONF_DIR="/opt/easytier"
    if is_synology; then
        SYN_BASE="$(get_synology_docker_dir)/easytier"
        info "检测到群晖 NAS 环境，推荐配置目录: ${CYAN}${SYN_BASE}${RESET}"
        printf "是否使用此目录？[Y/n]: "
        read -r use_syn
        if [[ "${use_syn:-Y}" =~ ^[Yy]$ ]]; then
            CONF_DIR="$SYN_BASE"
            info "已设置配置目录: ${CYAN}${CONF_DIR}${RESET}"
        else
            info "保持默认目录: ${CYAN}${CONF_DIR}${RESET}"
        fi
    fi
else
    CONF_DIR="/etc/easytier"
fi

TARGET_VERSION=""
sleep 1

get_docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

get_arch() {
    local arch=$(uname -m)
    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        echo "aarch64"
    else
        echo "x86_64"
    fi
}

ask_version() {
    if [ "$ENV_TYPE" = "docker" ]; then
        echo -e "\n${BOLD}${CYAN}=== Docker 镜像版本设置 ===${RESET}"
        echo -e "${YELLOW}👉 [说明] Docker 环境推荐直接使用 latest 标签，以便随时获取最新稳定版。${RESET}"
        printf "请输入镜像版本号 (回车默认使用 ${CYAN}latest${RESET}，如需指定请输入例如 v2.6.4): "
        read -r input_ver
        TARGET_VERSION="${input_ver:-latest}"
        info "部署将使用 Docker 镜像版本: ${CYAN}${TARGET_VERSION}${RESET}"
        return
    fi

    [ "$ENV_TYPE" = "macos" ] && info "正在从 GitHub 获取 Mac 版最新信息..." || info "正在从 GitHub 获取最新版本信息..."
    command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl 2>/dev/null || yum install -y curl 2>/dev/null || true; }

    # 优先使用 GitHub API 获取最新版本
    local fetched_ver=""
    fetched_ver=$(curl -s "https://api.github.com/repos/EasyTier/EasyTier/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)

    # API 失败时的 fallback 方案 (重定向解析)
    if [ -z "$fetched_ver" ]; then
        warn "API 请求失败，尝试通过跳转解析获取..."
        for base in "${RELEASE_BASES[@]}"; do
            local test_url="${base}/latest"
            local latest_url=$(curl -Ls -m 6 -o /dev/null -w '%{url_effective}' "$test_url" 2>/dev/null || true)
            if [[ "$latest_url" =~ tag/(v[0-9]+(\.[0-9]+)+.*) ]]; then
                fetched_ver="${BASH_REMATCH[1]}"
                break
            fi
        done
    fi

    if [ -z "$fetched_ver" ]; then
        fetched_ver="v2.6.4"
        warn "获取最新版本失败，使用保底版本 v2.6.4"
    fi

    echo -e "\n检测到当前可用版本为: ${CYAN}${fetched_ver}${RESET}"
    printf "请输入你要部署的版本号 (回车默认使用 ${CYAN}${fetched_ver}${RESET}): "
    
    read -r input_ver
    TARGET_VERSION="${input_ver:-$fetched_ver}"
    info "部署版本: ${CYAN}${TARGET_VERSION}${RESET}"
}

download_binary() {
    local version="$1"
    local arch=$(get_arch)
    local os_str="linux"
    [ "$ENV_TYPE" = "macos" ] && os_str="macos"
    local file="easytier-${os_str}-${arch}-${version}.zip"

    command -v unzip >/dev/null 2>&1 || { apt-get update && apt-get install -y unzip 2>/dev/null || yum install -y unzip 2>/dev/null || true; }

    local download_success=0
    for base in "${RELEASE_BASES[@]}"; do
        local url="${base}/download/${version}/${file}"
        local mirror_name="GitHub"
        [[ "$base" == *"kkgithub"* ]] && mirror_name="KKGitHub"
        [[ "$base" == *"ghproxy"* ]] && mirror_name="GHProxy"
        [[ "$base" == *"moeyy"* ]] && mirror_name="Moeyy"
        
        info "尝试下载源: ${mirror_name} ..."
        if curl -fL -m 60 "$url" -o /tmp/easytier.zip >/dev/null 2>&1; then
            download_success=1
            break
        fi
    done

    if [ $download_success -eq 0 ]; then
        error "所有镜像源均下载失败，请检查网络！"
        return 1
    fi

    rm -rf /tmp/easytier_out
    unzip -o /tmp/easytier.zip -d /tmp/easytier_out > /dev/null

    local core_bin=$(find /tmp/easytier_out -type f -name "easytier-core" | head -n 1 || true)
    local cli_bin=$(find  /tmp/easytier_out -type f -name "easytier-cli"  | head -n 1 || true)

    if [ -z "$core_bin" ] || [ -z "$cli_bin" ]; then
        error "未找到核心文件！解压异常。"
        rm -rf /tmp/easytier.zip /tmp/easytier_out
        return 1
    fi

    cp "$core_bin" /usr/local/bin/easytier-core
    cp "$cli_bin"  /usr/local/bin/easytier-cli
    chmod +x /usr/local/bin/easytier-core /usr/local/bin/easytier-cli
    
    # 修复 macOS 签名问题
    if [ "$ENV_TYPE" = "macos" ]; then
        info "正在对二进制文件进行 macOS 签名修复..."
        codesign --remove-signature /usr/local/bin/easytier-core 2>/dev/null || true
        codesign --force --deep --sign - /usr/local/bin/easytier-core
        
        codesign --remove-signature /usr/local/bin/easytier-cli 2>/dev/null || true
        codesign --force --deep --sign - /usr/local/bin/easytier-cli
    fi

    # 二进制完整性校验
    if ! /usr/local/bin/easytier-core --help >/dev/null 2>&1; then
        error "核心程序校验失败，下载的文件可能已损坏或架构不匹配！"
        rm -rf /tmp/easytier.zip /tmp/easytier_out
        return 1
    fi

    rm -rf /tmp/easytier.zip /tmp/easytier_out
    success "核心程序安装完毕并通过校验！"
}

do_configure() {
    echo -e "\n${BOLD}${CYAN}=== 配置 EasyTier 组网 ===${RESET}"

    local conf_file="${CONF_DIR}/.env"
    local cur_hostname="" cur_net_name="" cur_net_secret="" cur_ipv4=""
    local cur_exit_node="N" cur_node_type="1" cur_proxy_nets="" old_peers=""
    local cur_sys_fwd=""

    if [ -f "$conf_file" ]; then
        info "检测到配置文件，正在读取..."
        source "$conf_file"
        cur_hostname="${ET_HOSTNAME:-}"
        cur_net_name="${ET_NET_NAME:-}"
        cur_net_secret="${ET_NET_SECRET:-}"
        cur_ipv4="${ET_IPV4:-}"
        cur_exit_node="${ET_EXIT_CHOICE:-N}"
        cur_node_type="${ET_NODE_TYPE:-1}"
        cur_proxy_nets="${ET_PROXY_NETS:-}"
        old_peers="${ET_PEERS:-}"
        cur_sys_fwd="${ET_SYS_FWD:-}"
    fi

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 设备名称用于在控制台里辨认机器，中英文均可。${RESET}"
    echo -e "${YELLOW}👉 [示例] Mac_Mini / Home_NAS / Office_PC${RESET}"
    local default_host="${cur_hostname:-$(hostname -s 2>/dev/null || echo 'easytier-node')}"
    printf "请输入设备名称 (默认: ${CYAN}%s${RESET}，回车保持): " "$default_host"
    read -r HOSTNAME
    HOSTNAME="${HOSTNAME:-$default_host}"

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 网络名称是私有局域网的唯一标识，所有需要互相访问的设备必须填同一个名字。${RESET}"
    echo -e "${YELLOW}👉 [示例] easytier_1 / family_vpn / my_secret_net${RESET}"
    printf "请输入你要创建或加入的【网络名称】 (当前: ${CYAN}%s${RESET}): " "${cur_net_name:-}"
    read -r NET_NAME
    NET_NAME="${NET_NAME:-$cur_net_name}"
    while [ -z "$NET_NAME" ]; do warn "网络名称不能为空: "; read -r NET_NAME; done

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 网络密码用于加密节点间的数据。同名网络的设备密码必须一致。${RESET}"
    echo -e "${YELLOW}👉 [示例] 12345678 (建议数字+字母的强密码)${RESET}"
    printf "请输入【网络密码】 (已设置则直接回车保持): "
    read -r NET_SECRET
    NET_SECRET="${NET_SECRET:-$cur_net_secret}"
    while [ -z "$NET_SECRET" ]; do warn "网络密码不能为空: "; read -r NET_SECRET; done

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 虚拟 IP 是此设备在 VPN 里的“身份证IP”，必须和真实的物理局域网网段错开。${RESET}"
    echo -e "${YELLOW}👉 [建议] 如果你不打算记它，直接敲回车，系统会随机分配一个 10.x.x.x 的地址。${RESET}"
    printf "请输入此设备的【虚拟 IP】 (当前: ${CYAN}%s${RESET}，回车自动分配，输'clear'清除): " "${cur_ipv4:-未设置}"
    read -r IPV4
    if   [ -z "$IPV4" ];        then IPV4="$cur_ipv4"
    elif [ "$IPV4" = "clear" ]; then IPV4=""
    fi

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 开启出口节点后，别的设备可以通过这台机器“全局代理”上网。${RESET}"
    printf "是否开启【出口节点】功能？[y/N] (当前: ${CYAN}%s${RESET}): " "$cur_exit_node"
    read -r EXIT_CHOICE
    EXIT_CHOICE="${EXIT_CHOICE:-$cur_exit_node}"
    local EXIT_ARG=""
    if [[ "$EXIT_CHOICE" =~ ^[Yy]$ ]]; then
        EXIT_ARG="--enable-exit-node"
        if [ "$ENV_TYPE" = "linux" ]; then
            echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-easytier.conf
            sysctl -p /etc/sysctl.d/99-easytier.conf >/dev/null 2>&1
            info "已开启 Linux IP 转发。"
        elif [ "$ENV_TYPE" = "macos" ]; then
            sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1
            # 持久化 macOS IP 转发
            grep -q "net.inet.ip.forwarding=1" /etc/sysctl.conf 2>/dev/null || echo "net.inet.ip.forwarding=1" >> /etc/sysctl.conf
            info "已开启 macOS IP 转发并写入 /etc/sysctl.conf 持久化。"
        fi
    fi

    # >>> 子网映射功能配置区 <<<
    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${BOLD}${YELLOW}=== 虚拟子网映射配置 (可选) ===${RESET}"
    echo -e "${YELLOW}👉 [示例] 输入 192.168.11.0/24，即代表将本地 10.x 网段伪装成 11.x 供外部访问。${RESET}"
    
    local PROXY_NET_ARG=""
    local SYS_FWD_ARG=""
    if [ -n "$cur_proxy_nets" ]; then
        local display_proxy=$(echo "$cur_proxy_nets" | sed 's/-n //g')
        info "读取到现有的子网映射配置: ${CYAN}${display_proxy}${RESET}"
        printf "是否保留并继续使用这些子网映射？[Y/n]: "
        read -r keep_proxy
        if [[ "${keep_proxy:-Y}" =~ ^[Yy]$ ]]; then
            PROXY_NET_ARG="$cur_proxy_nets"
        else
            info "已清除旧子网映射记录，请重新输入。"
        fi
    fi
    
    while true; do
        printf "请输入要【宣告/映射】的虚拟子网网段 (回车跳过): "
        read -r PROXY_INPUT
        [ -n "$PROXY_INPUT" ] && PROXY_NET_ARG="${PROXY_NET_ARG} -n ${PROXY_INPUT}"
        [ -z "$PROXY_INPUT" ] && break
        printf "是否继续添加其他映射网段？[y/N]: "
        read -r add_more
        [[ ! "${add_more:-N}" =~ ^[Yy]$ ]] && break
    done

    if [ -n "$PROXY_NET_ARG" ]; then
        SYS_FWD_ARG="--proxy-forward-by-system true"
    fi

    echo -e "\n${CYAN}------------------------------------------------${RESET}"
    echo -e "${YELLOW}👉 [说明] 选择设备的工作模式：${RESET}"
    echo -e " 1) 纯客户端 (不占用端口，仅向外连接)"
    echo -e " 2) 纯中心节点 (开启 11010 端口侦听，等待别人连入)"
    echo -e " 3) 双核节点 (既开启侦听，又主动连接其他节点)"
    printf "请选择此设备角色 [1/2/3] (当前: ${CYAN}%s${RESET}，回车保持): " "$cur_node_type"
    read -r NODE_TYPE
    NODE_TYPE="${NODE_TYPE:-$cur_node_type}"

    local LISTENER_ARG="" PEER_ARG=""
    if [ "$NODE_TYPE" = "2" ] || [ "$NODE_TYPE" = "3" ]; then
        LISTENER_ARG="--listeners tcp://0.0.0.0:11010 udp://0.0.0.0:11010"
    fi

    if [ "$NODE_TYPE" = "1" ] || [ "$NODE_TYPE" = "3" ]; then
        if [ -n "$old_peers" ]; then
            local display_peers=$(echo "$old_peers" | sed 's/--peers //g')
            info "读取到现有中心节点: ${CYAN}${display_peers}${RESET}"
            printf "是否保留这些节点？[Y/n]: "
            read -r keep_peers
            if [[ "${keep_peers:-Y}" =~ ^[Yy]$ ]]; then
                PEER_ARG="$old_peers"
            else
                info "已清除旧节点记录。"
            fi
        fi

        echo -e "\n${CYAN}------------------------------------------------${RESET}"
        while true; do
            printf "请输入要【新增】的中心节点地址 (回车跳过): "
            read -r PEER_URI
            [ -n "$PEER_URI" ] && PEER_ARG="${PEER_ARG} --peers ${PEER_URI}"
            [ -z "$PEER_URI" ] && break
            printf "是否继续添加节点？[y/N]: "
            read -r add_more
            [[ ! "${add_more:-N}" =~ ^[Yy]$ ]] && break
        done
    fi

    local IPV4_ARG=""
    [ -n "$IPV4" ] && IPV4_ARG="--ipv4 $IPV4"

    mkdir -p "$CONF_DIR"
    cat <<EOF > "${CONF_DIR}/.env"
ET_HOSTNAME="${HOSTNAME}"
ET_NET_NAME="${NET_NAME}"
ET_NET_SECRET="${NET_SECRET}"
ET_IPV4="${IPV4}"
ET_EXIT_CHOICE="${EXIT_CHOICE}"
ET_NODE_TYPE="${NODE_TYPE}"
ET_PROXY_NETS="${PROXY_NET_ARG}"
ET_SYS_FWD="${SYS_FWD_ARG}"
ET_PEERS="${PEER_ARG}"
EOF
    chmod 600 "${CONF_DIR}/.env"

    info "正在应用配置..."

    if [ "$ENV_TYPE" = "linux" ] || [ "$ENV_TYPE" = "macos" ]; then
        local start_sh="${CONF_DIR}/start.sh"
        # 写入启动脚本，收敛参数，防止暴露在系统服务配置文件中
        cat <<EOF > "$start_sh"
#!/bin/bash
/usr/local/bin/easytier-core \\
  --hostname "${HOSTNAME}" \\
  --network-name "${NET_NAME}" \\
  --network-secret "${NET_SECRET}" \\
  ${IPV4_ARG} \\
  ${EXIT_ARG} \\
  ${LISTENER_ARG} \\
  ${PROXY_NET_ARG} \\
  ${SYS_FWD_ARG} \\
  ${PEER_ARG}
EOF
        chmod 700 "$start_sh"
    fi

    if [ "$ENV_TYPE" = "linux" ]; then
        cat <<EOF > /etc/systemd/system/easytier.service
[Unit]
Description=EasyTier Node
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONF_DIR}/start.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable easytier >/dev/null 2>&1
        systemctl restart easytier
        sleep 4
        if systemctl is-active --quiet easytier; then
            success "配置完成！Linux 后台服务拉起成功。"
        else
            error "启动失败！请运行 journalctl -u easytier -n 30 查看。"
        fi

    elif [ "$ENV_TYPE" = "macos" ]; then
        mkdir -p /usr/local/var/log
        cat <<EOF > /Library/LaunchDaemons/com.easytier.node.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.easytier.node</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${CONF_DIR}/start.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/usr/local/var/log/easytier.log</string>
    <key>StandardErrorPath</key>
    <string>/usr/local/var/log/easytier.err</string>
</dict>
</plist>
EOF
        # 兼容处理 Launchctl 命令
        launchctl bootout system /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || launchctl unload /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || true
        launchctl bootstrap system /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || launchctl load /Library/LaunchDaemons/com.easytier.node.plist
        sleep 4
        if launchctl list | grep -q com.easytier.node; then
            success "配置完成！macOS 后台服务拉起成功。"
        else
            error "启动失败！请查看 /usr/local/var/log/easytier.err 获取详细信息。"
        fi

    elif [ "$ENV_TYPE" = "docker" ]; then
        local dcmd=$(get_docker_compose_cmd)
        local docker_img_tag="${TARGET_VERSION:-latest}"

        mkdir -p "${CONF_DIR}/data"
        cat <<EOF > "${CONF_DIR}/docker-compose.yml"
version: '3.8'
services:
  easytier:
    image: easytier/easytier:${docker_img_tag}
    container_name: easytier
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ${CONF_DIR}/data:/root
    command: >
      --hostname "${HOSTNAME}"
      --network-name "${NET_NAME}"
      --network-secret "${NET_SECRET}"
      ${IPV4_ARG}
      ${EXIT_ARG}
      ${LISTENER_ARG}
      ${PROXY_NET_ARG}
      ${SYS_FWD_ARG}
      ${PEER_ARG}
EOF
        cd "$CONF_DIR"
        $dcmd down 2>/dev/null || true
        $dcmd up -d
        sleep 4
        if docker ps | grep -q easytier; then
            success "配置完成！Docker 容器成功拉起。"
        else
            error "启动失败！请通过 $dcmd -f ${CONF_DIR}/docker-compose.yml logs 查看日志。"
        fi
    fi
}

show_status() {
    if [ "$ENV_TYPE" = "linux" ]; then
        if systemctl is-active --quiet easytier; then
            echo -e "\n${GREEN}● Linux 服务运行中${RESET}"
            if /usr/local/bin/easytier-cli peer >/dev/null 2>&1; then
                /usr/local/bin/easytier-cli peer
            else
                warn "RPC接口未开启或连接失败，改为显示进程状态："
                ps aux | grep easytier-core | grep -v grep
            fi
        else
            echo -e "\n${RED}● 服务未运行${RESET}"
        fi
    elif [ "$ENV_TYPE" = "macos" ]; then
        if launchctl list | grep -q com.easytier.node; then
            echo -e "\n${GREEN}● macOS 服务运行中${RESET}"
            if /usr/local/bin/easytier-cli peer >/dev/null 2>&1; then
                /usr/local/bin/easytier-cli peer
            else
                warn "RPC接口未开启或连接失败，改为显示进程状态："
                ps aux | grep easytier-core | grep -v grep
            fi
        else
            echo -e "\n${RED}● 服务未运行${RESET}"
        fi
    elif [ "$ENV_TYPE" = "docker" ]; then
        if docker ps | grep -q easytier; then
            echo -e "\n${GREEN}● Docker 容器运行中${RESET}"
            if docker exec easytier easytier-cli peer >/dev/null 2>&1; then
                docker exec easytier easytier-cli peer
            else
                warn "RPC接口未开启或连接失败，改为显示容器日志尾部："
                docker logs --tail 10 easytier
            fi
        else
            echo -e "\n${RED}● 容器未运行${RESET}"
        fi
    fi
}

do_update() {
    ask_version
    if [ "$ENV_TYPE" = "docker" ]; then
        local dcmd=$(get_docker_compose_cmd)
        local docker_img_tag="${TARGET_VERSION:-latest}"

        local dc_file="${CONF_DIR}/docker-compose.yml"
        if [ ! -f "$dc_file" ]; then
            error "未找到 ${dc_file}，请先执行安装（选项1）。"
            return 1
        fi

        sed -i "s|image: easytier/easytier:.*|image: easytier/easytier:${docker_img_tag}|g" "$dc_file"
        cd "$CONF_DIR" && $dcmd pull && $dcmd up -d
        success "Docker 容器更新/降级完成！"
    else
        if [ "$ENV_TYPE" = "linux" ]; then
            systemctl stop easytier 2>/dev/null || true
        elif [ "$ENV_TYPE" = "macos" ]; then
            launchctl bootout system /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || launchctl unload /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || true
        fi
        
        download_binary "$TARGET_VERSION"
        
        if [ "$ENV_TYPE" = "linux" ]; then
            systemctl start easytier || true
        elif [ "$ENV_TYPE" = "macos" ]; then
            launchctl bootstrap system /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || launchctl load /Library/LaunchDaemons/com.easytier.node.plist || true
        fi
        success "程序更新/降级完成！"
    fi
}

do_logs() {
    if [ "$ENV_TYPE" = "linux" ]; then
        echo -e "${CYAN}按 Ctrl+C 退出日志监控${RESET}"
        journalctl -u easytier -f
    elif [ "$ENV_TYPE" = "macos" ]; then
        echo -e "${CYAN}按 Ctrl+C 退出日志监控${RESET}"
        tail -f /usr/local/var/log/easytier.log /usr/local/var/log/easytier.err
    elif [ "$ENV_TYPE" = "docker" ]; then
        echo -e "${CYAN}按 Ctrl+C 退出日志监控${RESET}"
        local dcmd=$(get_docker_compose_cmd)
        cd "$CONF_DIR" && $dcmd logs -f
    fi
}

do_uninstall() {
    printf "${RED}警告：这将彻底删除程序及所有配置数据，确认吗？[y/N]: ${RESET}"
    read -r ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
        if [ "$ENV_TYPE" = "linux" ]; then
            systemctl stop    easytier 2>/dev/null || true
            systemctl disable easytier 2>/dev/null || true
            rm -f /etc/systemd/system/easytier.service
            systemctl daemon-reload
            rm -f /usr/local/bin/easytier-core /usr/local/bin/easytier-cli
            rm -rf "$CONF_DIR"
            rm -f /etc/sysctl.d/99-easytier.conf
            success "已清理干净。"

        elif [ "$ENV_TYPE" = "macos" ]; then
            launchctl bootout system /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || launchctl unload /Library/LaunchDaemons/com.easytier.node.plist 2>/dev/null || true
            rm -f /Library/LaunchDaemons/com.easytier.node.plist
            rm -f /usr/local/bin/easytier-core /usr/local/bin/easytier-cli
            rm -rf "$CONF_DIR"
            rm -f /usr/local/var/log/easytier.log /usr/local/var/log/easytier.err
            success "macOS 相关文件已彻底清理。"

        elif [ "$ENV_TYPE" = "docker" ]; then
            local dcmd=$(get_docker_compose_cmd)
            if [ -d "$CONF_DIR" ]; then
                cd "$CONF_DIR" && $dcmd down 2>/dev/null || true
            fi
            rm -rf "$CONF_DIR"
            success "已清理干净。"
        fi
    else
        info "操作取消。"
    fi
}

# ================================================================
# 主菜单
# ================================================================
while true; do
    echo -e "\n${BOLD}${BLUE}=====================================${RESET}"
    echo -e "${BOLD}${BLUE}   EasyTier 控制台 (${ENV_TYPE} 模式)    ${RESET}"
    echo -e "${BOLD}${BLUE}=====================================${RESET}"
    echo -e "  ${GREEN}1.${RESET} 全新安装与配置 (需下载核心)"
    echo -e "  ${GREEN}2.${RESET} 仅修改网络配置 (不下载，秒重启)"
    echo -e "  ${GREEN}3.${RESET} 手动指定版本并强制更新"
    echo -e "  ${GREEN}4.${RESET} 查看网络节点状态"
    echo -e "  ${GREEN}5.${RESET} 查看实时运行日志"
    echo -e "  ${RED}6.${RESET} 彻底卸载清理"
    echo -e "  ${YELLOW}0.${RESET} 退出"
    echo -e "${BOLD}=====================================${RESET}"
    printf "请选择 [0-6]: "
    read -r choice

    case "$choice" in
        1)
            ask_version
            [ "$ENV_TYPE" != "docker" ] && download_binary "$TARGET_VERSION"
            do_configure
            ;;
        2)
            if [ "$ENV_TYPE" != "docker" ] && [ ! -f "/usr/local/bin/easytier-core" ]; then
                error "未找到核心程序，请先执行选项 1 进行安装。"
            else
                do_configure
            fi
            ;;
        3) do_update ;;
        4) show_status ;;
        5) do_logs ;;
        6) do_uninstall ;;
        0) exit 0 ;;
        *) warn "无效选项！" ;;
    esac
done
