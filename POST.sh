#!/bin/sh
set -e

# --- Configurações Visuais ---
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
NC='\033[0m'

info() { echo -e "${AMARELO}[*] $1${NC}"; }
sucesso() { echo -e "${VERDE}[+] $1${NC}"; }
erro() { echo -e "${VERMELHO}[-] $1${NC}"; exit 1; }

# --- Verificações Iniciais ---
if [ "$EUID" -ne 0 ]; then
  erro "Execute este script como root (sudo)."
fi

USER_NAME="vinicius"

# --- Identificação do Sistema ---
. /etc/os-release

# Verifica a família do sistema operacional
if [[ "$ID" == "fedora" ]]; then
    OS_FAMILY="fedora"
    PKG_MGR="dnf"
elif [[ "$ID" == "almalinux" || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"centos"* ]]; then
    OS_FAMILY="rhel"
    PKG_MGR="dnf"
    RHEL_VERSION=$(echo $VERSION_ID | cut -d '.' -f 1)
elif [[ "$ID" == "ubuntu" || "$ID_LIKE" == *"ubuntu"* || "$ID_LIKE" == *"debian"* ]]; then
    OS_FAMILY="debian"
    PKG_MGR="apt"
    ARCH=$(dpkg --print-architecture)
    
    BASE_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
    
    # Mapeia o codinome para a numeração engessada exigida pelos repositórios da Microsoft
    case $BASE_CODENAME in
        bionic)   UBUNTU_VERSION="18.04" ;;
        focal)    UBUNTU_VERSION="20.04" ;;
        jammy)    UBUNTU_VERSION="22.04" ;;
        noble)    UBUNTU_VERSION="24.04" ;;
        *)        erro "Versão base ($BASE_CODENAME) não suportada pelos repositórios da Microsoft." ;;
    esac
else
    erro "Distribuição não suportada: $PRETTY_NAME"
fi

info "Iniciando a configuração para: $USER_NAME"
if [[ "$OS_FAMILY" == "debian" ]]; then
    info "Sistema detectado: $PRETTY_NAME (Base: Ubuntu $UBUNTU_VERSION / $BASE_CODENAME)"
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    info "Sistema detectado: $PRETTY_NAME (Base: RHEL $RHEL_VERSION)"
else
    info "Sistema detectado: $PRETTY_NAME"
fi

# --- Lista de Aplicativos Flatpak (Compartilhada) ---
FLATPAKS=(
  com.getpostman.Postman com.github.tchx84.Flatseal
  com.mattjakeman.ExtensionManager com.mikrotik.WinBox
  com.obsproject.Studio com.spotify.Client dev.vencord.Vesktop
  io.dbeaver.DBeaverCommunity io.github.flattool.Ignition io.github.flattool.Warehouse
  io.missioncenter.MissionCenter md.obsidian.Obsidian org.filezillaproject.Filezilla
  org.gaphor.Gaphor org.gnome.Boxes org.libreoffice.LibreOffice
  org.onlyoffice.desktopeditors org.qbittorrent.qBittorrent
  org.remmina.Remmina org.telegram.desktop org.videolan.VLC
)

# ==========================================
# FUNÇÕES DE INSTALAÇÃO E CONFIGURAÇÃO
# ==========================================

atualizar_sistema() {
    info "Atualizando pacotes do sistema..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf upgrade --refresh -y
    else
        apt update && apt upgrade -y
    fi
    sucesso "Sistema atualizado."
}

configurar_repositorios() {
    info "Configurando repositórios (Docker, Microsoft)..."
    
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y curl gnupg2 jq tar gcc gcc-c++ make dnf-plugins-core
        
        if [[ "$OS_FAMILY" == "rhel" ]]; then
            dnf install -y epel-release
            dnf config-manager --set-enabled crb || true
            curl -sL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
            curl -sL https://packages.microsoft.com/config/rhel/${RHEL_VERSION}/prod.repo -o /etc/yum.repos.d/msprod.repo
        else
            curl -sL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
            curl -sL https://packages.microsoft.com/config/rhel/9/prod.repo -o /etc/yum.repos.d/msprod.repo
        fi

        rpm --import https://packages.microsoft.com/keys/microsoft.asc
        cat <<EOF > /etc/yum.repos.d/vscode.repo
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

    else
        install -m 0755 -d /etc/apt/keyrings
        apt install -y ca-certificates curl gnupg ufw gufw
        
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        cat <<EOF > /etc/apt/sources.list.d/docker.sources
Types: deb
Architectures: $ARCH
URIs: https://download.docker.com/linux/ubuntu
Suites: $BASE_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        if [[ "18.04 20.04 22.04 24.04 25.10" == *"$UBUNTU_VERSION"* ]]; then
            curl -sSL -O "https://packages.microsoft.com/config/ubuntu/$UBUNTU_VERSION/packages-microsoft-prod.deb"
            dpkg -i packages-microsoft-prod.deb
            rm packages-microsoft-prod.deb
        fi
        
        curl -fSsL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
        echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | tee /etc/apt/sources.list.d/vscode.list > /dev/null
    fi
    sucesso "Repositórios configurados."
}

instalar_pacotes_base() {
    info "Instalando pacotes base e utilitários..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y flatpak code zsh git curl jq docker-ce docker-ce-cli \
            containerd.io docker-buildx-plugin docker-compose-plugin php composer \
            php-devel php-xml php-pear msodbcsql18 mssql-tools18 unixODBC-devel
    else
        local EXTRAS="code"
        [[ "$ID" == "ubuntu" ]] && EXTRAS="code gnome-software gnome-software-plugin-flatpak"
        
        apt install -y flatpak zsh git curl jq docker-ce docker-ce-cli \
            containerd.io docker-buildx-plugin docker-compose-plugin php composer \
            php-dev php-xml php-pear $EXTRAS
            
        ACCEPT_EULA=Y apt install -y msodbcsql18 mssql-tools18 unixodbc-dev
    fi
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' > /etc/profile.d/mssql-tools.sh
    sucesso "Pacotes e MS SQL instalados."
}

configurar_solaar() {
    info "Configurando o Solaar e permissões UDEV..."
    
    getent group plugdev >/dev/null || groupadd plugdev
    usermod -aG plugdev $USER_NAME

    if [[ "$OS_FAMILY" == "fedora" ]]; then
        dnf install -y solaar
    elif [[ "$OS_FAMILY" == "debian" ]]; then
        add-apt-repository -y ppa:solaar-unifying/stable
        apt update
        apt install -y solaar
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        dnf install -y python3-pip python3-devel python3-gobject gtk3
        pip3 install solaar --break-system-packages 2>/dev/null || pip3 install solaar
        
        # Cria atalho no menu de aplicativos para distros RHEL
        mkdir -p /usr/share/applications /usr/share/icons/hicolor/scalable/apps
        curl -sL https://raw.githubusercontent.com/pwr-Solaar/Solaar/master/share/applications/solaar.desktop -o /usr/share/applications/solaar.desktop
        curl -sL https://raw.githubusercontent.com/pwr-Solaar/Solaar/master/share/solaar/icons/solaar-icon.svg -o /usr/share/icons/hicolor/scalable/apps/solaar.svg
    fi

    # Baixa a regra atualizada com suporte a Wayland e Uinput
    curl -sL https://raw.githubusercontent.com/pwr-Solaar/Solaar/master/rules.d-uinput/42-logitech-unify-permissions.rules -o /etc/udev/rules.d/42-logitech-unify-permissions.rules
    
    # Recarrega as regras e força o gatilho nos módulos USB e HID imediatamente
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb
    udevadm trigger --subsystem-match=hidraw
    
    sucesso "Solaar configurado."
}

remover_libreoffice_nativo() {
    info "Removendo LibreOffice pré-instalado..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf remove -y libreoffice*
    else
        apt remove --purge -y libreoffice*
    fi
    sucesso "LibreOffice nativo removido."
}

instalar_flatpaks() {
    info "Configurando Flatpak e instalando apps..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub "${FLATPAKS[@]}"
    sucesso "Aplicativos Flatpak instalados."
}

configurar_extensoes_php() {
    info "Compilando extensões PHP (sqlsrv)..."
    pecl install sqlsrv pdo_sqlsrv
    
    if [[ "$PKG_MGR" == "dnf" ]]; then
        echo "extension=sqlsrv.so" > /etc/php.d/20-sqlsrv.ini
        echo "extension=pdo_sqlsrv.so" > /etc/php.d/20-pdo_sqlsrv.ini
    else
        PHP_V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        printf "; priority=20\nextension=sqlsrv.so\n" > /etc/php/$PHP_V/mods-available/sqlsrv.ini
        printf "; priority=20\nextension=pdo_sqlsrv.so\n" > /etc/php/$PHP_V/mods-available/pdo_sqlsrv.ini
        phpenmod sqlsrv pdo_sqlsrv
    fi
    sucesso "Extensões PHP configuradas."
}

instalar_chrome_e_gcm() {
    info "Instalando Git Credential Manager e Google Chrome..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        GCM_URL=$(curl -sL https://api.github.com/repos/git-ecosystem/git-credential-manager/releases/latest | jq -r '.assets[] | select(.name | endswith(".tar.gz") and contains("linux-x64") and (contains("symbols") | not)) | .browser_download_url' | head -n 1)
        curl -sSL -o /tmp/gcm.tar.gz "$GCM_URL"
        mkdir -p /usr/local/gcm
        tar -xzf /tmp/gcm.tar.gz -C /usr/local/gcm
        ln -sf /usr/local/gcm/git-credential-manager /usr/local/bin/git-credential-manager

        curl -sSL -o /tmp/chrome.rpm https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
        dnf install -y /tmp/chrome.rpm
    else
        GCM_URL=$(curl -sL https://api.github.com/repos/git-ecosystem/git-credential-manager/releases/latest | jq -r '.assets[] | select(.name | endswith(".deb") and contains("linux-x64")) | .browser_download_url' | head -n 1)
        curl -sSL -o /tmp/gcm.deb "$GCM_URL"
        apt install -y /tmp/gcm.deb

        curl -sSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        apt install -y /tmp/chrome.deb
    fi
    sucesso "Chrome e GCM instalados."
}

instalar_bitwarden_nativo() {
    info "Instalando Bitwarden nativo (integração com navegador)..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        curl -sSL -o /tmp/bitwarden.rpm "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=rpm"
        dnf install -y /tmp/bitwarden.rpm
    else
        curl -sSL -o /tmp/bitwarden.deb "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb"
        apt install -y /tmp/bitwarden.deb
    fi
    sucesso "Bitwarden instalado nativamente."
}

configurar_usuario() {
    info "Aplicando configurações locais para $USER_NAME..."
    usermod -aG docker $USER_NAME
    chsh -s $(which zsh) $USER_NAME

    su - $USER_NAME -c "
  # NVM e Node LTS
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR=\"\$HOME/.nvm\"
  [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
  nvm install --lts && nvm use --lts && nvm alias default \"lts/*\"
  
  # Git Credential Manager
  git-credential-manager configure
  git config --global credential.credentialStore secretservice
  
  # Oh My Zsh
  curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | RUNZSH=no CHSH=no sh
  
  # Repositório Dotfiles
  git clone https://github.com/vinicgobbi/Dotfiles.git /tmp/dotfiles
  mkdir -p ~/.config/solaar ~/.local/share/fonts ~/.oh-my-zsh/custom
  
  cp -r /tmp/dotfiles/config/solaar/* ~/.config/solaar/ 2>/dev/null || true
  cp -r /tmp/dotfiles/fonts/* ~/.local/share/fonts/ 2>/dev/null || true
  cp -r /tmp/dotfiles/oh-my-zsh/custom/* ~/.oh-my-zsh/custom/ 2>/dev/null || true
  
  # ZSH Theme e Fontes
  sed -i 's/ZSH_THEME=\".*\"/ZSH_THEME=\"detail\"/' ~/.zshrc
  fc-cache -f -v

  # Diretório de Projetos (XDG e Bookmarks)
  if [[ \"\$LANG\" == pt_* ]]; then
      DIR_NAME=\"Projetos\"
  else
      DIR_NAME=\"Projects\"
  fi
  PROJECTS_DIR=\"\$HOME/\$DIR_NAME\"
  mkdir -p \"\$PROJECTS_DIR\"
  
  xdg-user-dirs-update --set PROJECTS \"\$PROJECTS_DIR\"
  
  BOOKMARKS_FILE=\"\$HOME/.config/gtk-3.0/bookmarks\"
  mkdir -p \"\$(dirname \"\$BOOKMARKS_FILE\")\"
  touch \"\$BOOKMARKS_FILE\"
  if ! grep -q \"file://\$PROJECTS_DIR\" \"\$BOOKMARKS_FILE\"; then
      echo \"file://\$PROJECTS_DIR\" >> \"\$BOOKMARKS_FILE\"
  fi

  # Autostart do Solaar
  mkdir -p \"\$HOME/.config/autostart\"
  cp /usr/share/applications/solaar.desktop \"\$HOME/.config/autostart/\" 2>/dev/null || true

  # Instalação e Aplicação do Tema adw-gtk3 (Apenas para distros não-Ubuntu)
  if [[ \"\$ID\" != \"ubuntu\" ]]; then
      mkdir -p \"\$HOME/.local/share/themes\" \"\$HOME/.themes\"
      
      ADW_URL=\$(curl -sL https://api.github.com/repos/lassekongo83/adw-gtk3/releases/latest | jq -r '.assets[] | select(.name | endswith(\".tar.xz\")) | .browser_download_url' | head -n 1)
      if [ -n \"\$ADW_URL\" ]; then
          curl -sSL \"\$ADW_URL\" | tar -xJ -C \"\$HOME/.local/share/themes/\"
          
          # Link para .themes (Flatpaks e apps antigos GTK3 leem daqui por padrão)
          ln -sf \"\$HOME/.local/share/themes/adw-gtk3\" \"\$HOME/.themes/adw-gtk3\"
          ln -sf \"\$HOME/.local/share/themes/adw-gtk3-dark\" \"\$HOME/.themes/adw-gtk3-dark\"
          
          # Configurações do GNOME via gsettings
          gsettings set org.gnome.desktop.interface gtk-theme \"adw-gtk3-dark\" 2>/dev/null || true
          gsettings set org.gnome.desktop.interface color-scheme \"prefer-dark\" 2>/dev/null || true
          gsettings set org.gnome.desktop.wm.preferences theme \"adw-gtk3-dark\" 2>/dev/null || true
          gsettings set org.gnome.shell.extensions.user-theme name \"\" 2>/dev/null || true
          
      fi
  fi
"
    sucesso "Ambiente de usuário configurado."
}

limpeza_final() {
    info "Limpando o sistema..."
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf autoremove -y
        dnf clean all
    else
        apt autoremove -y
        apt clean
    fi
    rm -rf /tmp/* 2>/dev/null || true
    sucesso "Instalação finalizada com sucesso!"
    info "Recomenda-se reiniciar a máquina para aplicar as mudanças de grupo e kernel."
}

# ==========================================
# EXECUÇÃO DO FLUXO
# ==========================================
atualizar_sistema
configurar_repositorios
instalar_pacotes_base
configurar_solaar
remover_libreoffice_nativo
instalar_flatpaks
configurar_extensoes_php
instalar_chrome_e_gcm
instalar_bitwarden_nativo
configurar_usuario
limpeza_final
