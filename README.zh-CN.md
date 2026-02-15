> 此翻译由 Claude 生成。如有改进建议，欢迎提交 PR。

<p align="center"><a href="README.md">English</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a></p>

<h1 align="center">cmux</h1>
<p align="center">基于 Ghostty 的 macOS 终端，带有垂直标签页和为 AI 编程代理设计的通知系统</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="下载 cmux macOS 版" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux 截图" width="900" />
</p>

## 功能特性

- **垂直标签页** — 侧边栏显示 git 分支、工作目录、监听端口和最新通知文本
- **通知提示环** — 当 AI 代理（Claude Code、OpenCode）需要您注意时，窗格会显示蓝色光环，标签页会高亮
- **通知面板** — 在一处查看所有待处理通知，快速跳转到最新未读通知
- **分割窗格** — 支持水平和垂直分割
- **内置浏览器** — 在终端旁边分割出浏览器窗格，提供从 [agent-browser](https://github.com/vercel-labs/agent-browser) 移植的可脚本化 API
- **可脚本化** — 通过 CLI 和 socket API 创建工作区、分割窗格、发送按键和自动化浏览器操作
- **原生 macOS 应用** — 使用 Swift 和 AppKit 构建，非 Electron。启动快速，内存占用低。
- **兼容 Ghostty** — 读取您现有的 `~/.config/ghostty/config` 配置文件中的主题、字体和颜色设置
- **GPU 加速** — 由 libghostty 驱动，渲染流畅

## 安装

### DMG（推荐）

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="下载 cmux macOS 版" width="180" />
</a>

打开 `.dmg` 文件并将 cmux 拖动到"应用程序"文件夹。cmux 通过 Sparkle 自动更新，您只需下载一次。

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

稍后更新：

```bash
brew upgrade --cask cmux
```

首次启动时，macOS 可能会要求您确认打开来自已验证开发者的应用。点击**打开**即可继续。

## 为什么做 cmux？

我同时运行大量 Claude Code 和 Codex 会话。之前我用 Ghostty 开了一堆分割窗格，依靠 macOS 原生通知来了解代理何时需要我。但 Claude Code 的通知内容总是千篇一律的"Claude is waiting for your input"，没有任何上下文信息，而且标签页一多，连标题都看不清了。

我试过几个编程协调工具，但大多数都是 Electron/Tauri 应用，性能让我不满意。我也更喜欢终端，因为 GUI 协调工具会把你锁定在它们的工作流里。所以我用 Swift/AppKit 构建了 cmux，作为一个原生 macOS 应用。它使用 libghostty 进行终端渲染，并读取您现有的 Ghostty 配置中的主题、字体和颜色设置。

主要新增的是侧边栏和通知系统。侧边栏有垂直标签页，显示每个工作区的 git 分支、工作目录、监听端口和最新通知文本。通知系统能捕获终端序列（OSC 9/99/777），并提供 CLI（`cmux notify`），您可以将其接入 Claude Code、OpenCode 等代理的钩子。当代理等待时，其窗格会显示蓝色光环，标签页会在侧边栏高亮，这样我就能在多个分割窗格和标签页之间一眼看出哪个需要我。⌘⇧U 可以跳转到最新的未读通知。

内置浏览器拥有从 [agent-browser](https://github.com/vercel-labs/agent-browser) 移植的可脚本化 API。代理可以抓取无障碍树快照、获取元素引用、执行点击、填写表单和执行 JS。您可以在终端旁边分割出浏览器窗格，让 Claude Code 直接与您的开发服务器交互。

所有操作都可以通过 CLI 和 socket API 进行脚本化 — 创建工作区/标签页、分割窗格、发送按键、在浏览器中打开 URL。

## 键盘快捷键

### 工作区

| 快捷键 | 操作 |
|----------|--------|
| ⌘ N | 新建工作区 |
| ⌘ 1–8 | 跳转到工作区 1–8 |
| ⌘ 9 | 跳转到最后一个工作区 |
| ⌘ ⇧ W | 关闭工作区 |

### 界面

| 快捷键 | 操作 |
|----------|--------|
| ⌘ T | 新建界面 |
| ⌘ ⇧ [ | 上一个界面 |
| ⌃ ⇧ Tab | 上一个界面 |
| ⌃ 1–8 | 跳转到界面 1–8 |
| ⌃ 9 | 跳转到最后一个界面 |
| ⌘ W | 关闭界面 |

### 分割窗格

| 快捷键 | 操作 |
|----------|--------|
| ⌘ D | 向右分割 |
| ⌘ ⇧ D | 向下分割 |
| ⌥ ⌘ ← → ↑ ↓ | 按方向切换焦点窗格 |

### 浏览器

| 快捷键 | 操作 |
|----------|--------|
| ⌘ ⇧ B | 在分割中打开浏览器 |
| ⌘ L | 聚焦地址栏 |
| ⌘ ] | 前进 |
| ⌘ R | 刷新页面 |
| ⌥ ⌘ I | 打开开发者工具 |

### 通知

| 快捷键 | 操作 |
|----------|--------|
| ⌘ ⇧ I | 显示通知面板 |
| ⌘ ⇧ U | 跳转到最新未读 |

### 查找

| 快捷键 | 操作 |
|----------|--------|
| ⌘ F | 查找 |
| ⌘ G / ⌘ ⇧ G | 查找下一个 / 上一个 |
| ⌘ ⇧ F | 隐藏查找栏 |
| ⌘ E | 使用选中内容进行查找 |

### 终端

| 快捷键 | 操作 |
|----------|--------|
| ⌘ K | 清除回滚缓冲区 |
| ⌘ C | 复制（有选中内容时） |
| ⌘ V | 粘贴 |
| ⌘ + / ⌘ - | 增大 / 减小字体 |
| ⌘ 0 | 重置字体大小 |

### 窗口

| 快捷键 | 操作 |
|----------|--------|
| ⌘ ⇧ N | 新建窗口 |
| ⌘ , | 设置 |
| ⌘ ⇧ R | 重新加载配置 |
| ⌘ Q | 退出 |

## 许可证

本项目采用 GNU Affero 通用公共许可证 v3.0 或更高版本（`AGPL-3.0-or-later`）授权。

完整许可证文本请参见 `LICENSE` 文件。
