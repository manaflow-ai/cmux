# syntax=docker/dockerfile:1.7-labs

# Stage 1: Build stage
FROM ubuntu:24.04 AS builder

ARG VERSION
ARG CODE_RELEASE
ARG DOCKER_VERSION=28.3.2
ARG DOCKER_CHANNEL=stable

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    python3 \
    make \
    g++ \
    bash \
    unzip \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24.x
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g node-gyp && \
    corepack enable && \
    corepack prepare pnpm@10.14.0 --activate

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/ && \
    ln -s /usr/local/bin/bun /usr/local/bin/bunx && \
    bun --version && \
    bunx --version

# Install openvscode-server (with retries and IPv4 fallback)
RUN if [ -z "${CODE_RELEASE}" ]; then \
    CODE_RELEASE=$(curl -sX GET "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest" \
      | awk '/tag_name/{print $4;exit}' FS='["\"]' \
      | sed 's|^openvscode-server-v||'); \
  fi && \
  echo "CODE_RELEASE=${CODE_RELEASE}" && \
  arch="$(dpkg --print-architecture)" && \
  if [ "$arch" = "amd64" ]; then \
    ARCH="x64"; \
  elif [ "$arch" = "arm64" ]; then \
    ARCH="arm64"; \
  fi && \
  mkdir -p /app/openvscode-server && \
  url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz" && \
  echo "Downloading: $url" && \
  ( \
    curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
    || curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
  ) && \
  tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && \
  rm -rf /tmp/openvscode-server.tar.gz

# Copy package files for monorepo dependency installation
WORKDIR /cmux
COPY package.json bun.lock .npmrc ./
COPY --parents apps/*/package.json packages/*/package.json scripts/package.json ./

RUN bun install --frozen-lockfile --production

RUN mkdir -p /builtins && \
    echo '{"name":"builtins","type":"module","version":"1.0.0"}' > /builtins/package.json
WORKDIR /builtins

# Copy source files needed for build
WORKDIR /cmux
# Copy shared package source and config
COPY packages/shared/src ./packages/shared/src
COPY packages/shared/tsconfig.json ./packages/shared/

# Copy convex package (needed by shared)
COPY packages/convex ./packages/convex/

# Copy worker source and scripts
COPY apps/worker/src ./apps/worker/src
COPY apps/worker/scripts ./apps/worker/scripts
COPY apps/worker/tsconfig.json ./apps/worker/
COPY apps/worker/wait-for-docker.sh ./apps/worker/

# Copy VS Code extension source
COPY packages/vscode-extension/src ./packages/vscode-extension/src
COPY packages/vscode-extension/tsconfig.json ./packages/vscode-extension/
COPY packages/vscode-extension/.vscodeignore ./packages/vscode-extension/
COPY packages/vscode-extension/LICENSE.md ./packages/vscode-extension/

# Build worker with bundling, using the installed node_modules
RUN cd /cmux && \
    bun build ./apps/worker/src/index.ts \
    --target node \
    --outdir ./apps/worker/build \
    --external @cmux/convex \
    --external node:* && \
    echo "Built worker" && \
    cp -r ./apps/worker/build /builtins/build && \
    cp ./apps/worker/wait-for-docker.sh /usr/local/bin/ && \
    chmod +x /usr/local/bin/wait-for-docker.sh

# Verify bun is still working in builder
RUN bun --version && bunx --version

# Build vscode extension
WORKDIR /cmux/packages/vscode-extension
RUN bun run package && cp cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix

# Install VS Code extensions
RUN /app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix && \
    rm /tmp/cmux-vscode-extension-0.0.1.vsix

# Stage 2: Runtime stage
FROM ubuntu:24.04 AS runtime

ARG DOCKER_VERSION=28.3.2
ARG DOCKER_CHANNEL=stable

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    python3 \
    bash \
    nano \
    net-tools \
    lsof \
    sudo \
    supervisor \
    iptables \
    openssl \
    pigz \
    xz-utils \
    tmux \
    htop \
    ripgrep \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24.x (runtime) and enable pnpm via corepack
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    corepack enable && \
    corepack prepare pnpm@10.14.0 --activate

# Copy Bun from builder
COPY --from=builder /usr/local/bin/bun /usr/local/bin/bun
COPY --from=builder /usr/local/bin/bunx /usr/local/bin/bunx

# Verify bun works in runtime
RUN bun --version && bunx --version

RUN bun add -g @openai/codex@0.36.0 @anthropic-ai/claude-code@1.0.83 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp

# Install cursor cli
RUN curl https://cursor.com/install -fsS | bash
RUN /root/.local/bin/cursor-agent --version

# Set iptables-legacy (required for Docker in Docker on Ubuntu 22.04+)
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy

# Install Docker
RUN <<-'EOF'
    set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) dockerArch='x86_64' ;; \
        aarch64) dockerArch='aarch64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    wget -O docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${DOCKER_VERSION}.tgz"; \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/; \
    rm docker.tgz; \
    dockerd --version; \
    docker --version
EOF

# Install Docker Compose and Buildx plugins
RUN <<-'EOF'
    set -eux; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    arch="$(uname -m)"; \
    # Install Docker Compose
    curl -SL "https://github.com/docker/compose/releases/download/v2.32.2/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    # Install Docker Buildx
    curl -SL "https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    echo "Docker plugins installed successfully"
EOF

# Skip docker-init installation - ubuntu-dind doesn't have it

# Set Bun path
ENV PATH="/usr/local/bin:$PATH"

# Copy only the built artifacts and runtime dependencies from builder
COPY --from=builder /app/openvscode-server /app/openvscode-server
COPY --from=builder /root/.openvscode-server /root/.openvscode-server
COPY --from=builder /root/.openvscode-server /opt/cmux/openvscode-defaults
COPY --from=builder /builtins /builtins
COPY --from=builder /usr/local/bin/wait-for-docker.sh /usr/local/bin/wait-for-docker.sh
COPY --from=builder /cmux/apps/worker/scripts/collect-relevant-diff.sh /usr/local/bin/cmux-collect-relevant-diff.sh
RUN chmod +x /usr/local/bin/cmux-collect-relevant-diff.sh

# Install envctl/envd into runtime
# Using direct download URL to avoid GitHub API rate limits
RUN CMUX_ENV_VERSION=0.0.8 && \
    arch="$(uname -m)" && \
    case "$arch" in \
        x86_64) arch_name="x86_64" ;; \
        aarch64|arm64) arch_name="aarch64" ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/lawrencecchen/cmux-env/releases/download/v${CMUX_ENV_VERSION}/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl/envctl /usr/local/bin/envctl && \
    mv /tmp/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl/envd /usr/local/bin/envd && \
    rm -rf /tmp/cmux-env-${CMUX_ENV_VERSION}-${arch_name}-unknown-linux-musl && \
    chmod +x /usr/local/bin/envctl /usr/local/bin/envd && \
    envctl --version && \
    envctl install-hook bash && \
    echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.profile && \
    echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.bash_profile && \
    mkdir -p /run/user/0 && \
    chmod 700 /run/user/0 && \
    echo 'export XDG_RUNTIME_DIR=/run/user/0' >> /root/.bashrc

# Install tmux configuration for better mouse scrolling behavior
COPY configs/tmux.conf /etc/tmux.conf

RUN claude_vsix=$(rg --files /root/.bun/install/cache/@anthropic-ai 2>/dev/null | rg "claude-code\.vsix$" | head -1) && \
    if [ -n "$claude_vsix" ]; then \
        echo "Found claude-code.vsix at: $claude_vsix" && \
        /app/openvscode-server/bin/openvscode-server --install-extension "$claude_vsix"; \
    else \
        echo "Warning: claude-code.vsix not found in Bun cache" && \
        exit 1; \
    fi

# Create modprobe script (required for DinD)
RUN <<-'EOF'
cat > /usr/local/bin/modprobe << 'SCRIPT'
#!/bin/sh
set -eu
# "modprobe" without modprobe
for module; do
    if [ "${module#-}" = "$module" ]; then
        ip link show "$module" || true
        lsmod | grep "$module" || true
    fi
done
# remove /usr/local/... from PATH so we can exec the real modprobe as a last resort
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'
exec modprobe "$@"
SCRIPT
chmod +x /usr/local/bin/modprobe
EOF

# Create workspace and lifecycle directories
RUN mkdir -p /workspace /root/workspace /root/lifecycle

VOLUME /var/lib/docker

# Create supervisor config for dockerd
# Based on https://github.com/cruizba/ubuntu-dind
RUN <<-'EOF'
mkdir -p /etc/supervisor/conf.d
cat > /etc/supervisor/conf.d/dockerd.conf << 'CONFIG'
[program:dockerd]
command=/usr/local/bin/dockerd
autostart=true
autorestart=true
stderr_logfile=/var/log/dockerd.err.log
stdout_logfile=/var/log/dockerd.out.log
CONFIG
EOF

# Copy startup script and prompt wrapper
COPY startup.sh /startup.sh
COPY prompt-wrapper.sh /usr/local/bin/prompt-wrapper
RUN chmod +x /startup.sh /usr/local/bin/prompt-wrapper

# Create VS Code user settings
RUN mkdir -p /root/.openvscode-server/data/User && \
    echo '{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]}' > /root/.openvscode-server/data/User/settings.json && \
    mkdir -p /root/.openvscode-server/data/User/profiles/default-profile && \
    echo '{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]}' > /root/.openvscode-server/data/User/profiles/default-profile/settings.json && \
    mkdir -p /root/.openvscode-server/data/Machine && \
    echo '{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]}' > /root/.openvscode-server/data/Machine/settings.json

# Ports
# 39376: VS Code Extension Socket Server
# 39377: Worker service
# 39378: OpenVSCode server
EXPOSE 39376 39377 39378

WORKDIR /

ENTRYPOINT ["/startup.sh"]
CMD []
