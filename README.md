<h1 align="center">cmux</h1>
<p align="center">open source Claude Code manager that supports Codex/Gemini/Cursor/OpenCode/Amp CLI</p>

<p align="center"><code>bunx cmux</code> or <code>npx cmux</code></p>

cmux lets you spawn Claude Code, Codex CLI, Cursor CLI, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel across multiple tasks.

Each agent runs in its own Docker container, launching VS Code with a Git diff UI and a terminal for its CLI.

![cmux screenshot](./docs/assets/cmux-demo-0.png)
![cmux screenshot](./docs/assets/cmux-demo-1.png)
![cmux screenshot](./docs/assets/cmux-demo-5.png)

## Install

cmux supports macOS Apple Silicon. macOS x64, Linux, and Windows support coming soon.

```bash
# with bun
bunx cmux@latest

# with npm
npx cmux@latest

# or to install globally
bun add -g cmux@latest
npm install -g cmux@latest
```

<!-- ```bash
# with uv
uvx cmux@latest
``` -->

<!-- ## Upgrade

```bash
cmux upgrade
``` -->

## Uninstall

```bash
cmux uninstall
```
