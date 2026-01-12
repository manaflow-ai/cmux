FROM node:24-bookworm

RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    git \
    zsh \
    curl \
    wget \
    sudo \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
ARG USERNAME=node
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Add sudo support for the non-root user and add to docker group
RUN echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME && \
    groupadd -f docker && \
    usermod -aG docker $USERNAME

# Install bun for runtime execution
USER $USERNAME
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/$USERNAME/.bun/bin:$PATH"

# Switch back to root for remaining setup
USER root

# Enable corepack for pnpm
RUN corepack enable && corepack prepare pnpm@10.14.0 --activate

# Install nvm and Node versions
ENV NVM_DIR=/home/$USERNAME/.nvm
RUN mkdir -p $NVM_DIR && \
    chown -R $USER_UID:$USER_GID $NVM_DIR

# Install nvm, Node 24 (default) and Node 18
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash && \
    . "$NVM_DIR/nvm.sh" && \
    nvm install 24 && \
    nvm install 18 && \
    nvm alias default 24 && \
    nvm use default

# Add nvm to shell
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.zshrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.zshrc && \
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ~/.zshrc

# Add bun to shell for the node user
RUN echo 'export PATH="/home/node/.bun/bin:$PATH"' >> /home/node/.zshrc && \
    echo 'export PATH="/home/node/.bun/bin:$PATH"' >> /home/node/.bashrc && \
    chown node:node /home/node/.zshrc /home/node/.bashrc

# Set up zsh completions directory and config for root user
RUN mkdir -p /root/.zsh/completions && \
    echo 'fpath=(~/.zsh/completions $fpath)' >> /root/.zshrc && \
    echo 'autoload -Uz compinit && compinit -C' >> /root/.zshrc

# Set up zsh completions for node user
RUN mkdir -p /home/node/.zsh/completions && \
    echo 'fpath=(~/.zsh/completions $fpath)' >> /home/node/.zshrc && \
    echo 'autoload -Uz compinit && compinit -C' >> /home/node/.zshrc && \
    chown -R node:node /home/node/.zsh

# Pre-create VS Code server settings directories with trust disabled
RUN mkdir -p /root/.code-server/User /root/.code-server/Machine \
             /root/.openvscode-server/data/User /root/.openvscode-server/data/Machine \
             /root/.vscode-server/data/User /root/.vscode-server/data/Machine && \
    SETTINGS='{"security.workspace.trust.enabled":false,"security.workspace.trust.untrustedFiles":"open","security.workspace.trust.startupPrompt":"never","security.workspace.trust.emptyWindow":true,"security.workspace.trust.banner":"never","chat.agent.enabled":false,"github.copilot.chat.agent.runTasks":false}' && \
    echo "$SETTINGS" > /root/.code-server/User/settings.json && \
    echo "$SETTINGS" > /root/.code-server/Machine/settings.json && \
    echo "$SETTINGS" > /root/.openvscode-server/data/User/settings.json && \
    echo "$SETTINGS" > /root/.openvscode-server/data/Machine/settings.json && \
    echo "$SETTINGS" > /root/.vscode-server/data/User/settings.json && \
    echo "$SETTINGS" > /root/.vscode-server/data/Machine/settings.json

# Also set up VS Code settings for node user
RUN mkdir -p /home/node/.code-server/User /home/node/.code-server/Machine \
             /home/node/.openvscode-server/data/User /home/node/.openvscode-server/data/Machine \
             /home/node/.vscode-server/data/User /home/node/.vscode-server/data/Machine && \
    SETTINGS='{"security.workspace.trust.enabled":false,"security.workspace.trust.untrustedFiles":"open","security.workspace.trust.startupPrompt":"never","security.workspace.trust.emptyWindow":true,"security.workspace.trust.banner":"never","chat.agent.enabled":false,"github.copilot.chat.agent.runTasks":false}' && \
    echo "$SETTINGS" > /home/node/.code-server/User/settings.json && \
    echo "$SETTINGS" > /home/node/.code-server/Machine/settings.json && \
    echo "$SETTINGS" > /home/node/.openvscode-server/data/User/settings.json && \
    echo "$SETTINGS" > /home/node/.openvscode-server/data/Machine/settings.json && \
    echo "$SETTINGS" > /home/node/.vscode-server/data/User/settings.json && \
    echo "$SETTINGS" > /home/node/.vscode-server/data/Machine/settings.json && \
    chown -R node:node /home/node/.code-server /home/node/.openvscode-server /home/node/.vscode-server

# Set up the workspace
WORKDIR /workspaces/cmux

# Install global npm packages using Node 24
RUN . "$NVM_DIR/nvm.sh" && nvm use 24 && npm install -g npm@latest

# Set up shell
ENV SHELL=/bin/zsh

# Create node_modules directories with correct permissions
RUN mkdir -p /workspaces/cmux/node_modules /workspaces/cmux/packages/convex/node_modules && \
    chown -R node:node /workspaces/cmux

# Copy and set entrypoint
COPY --chown=node:node .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]