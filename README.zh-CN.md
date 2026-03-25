> 此翻译由 Claude 生成。如有改进建议，欢迎提交 PR。

<h1 align="center">cmux</h1>
<p align="center">基于 Ghostty 的 macOS 终端，带有垂直标签页和为 AI 编程代理设计的通知系统</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="下载 cmux macOS 版" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux 截图" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ 演示视频</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## 功能特性

<table>
<tr>
<td width="40%" valign="middle">
<h3>通知提示环</h3>
当编程代理需要您注意时，窗格会显示蓝色光环，标签页会高亮
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="通知提示环" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>通知面板</h3>
在一处查看所有待处理通知，快速跳转到最新未读通知
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="侧边栏通知徽章" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>内置浏览器</h3>
在终端旁边分割出浏览器窗格，提供从 <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a> 移植的可脚本化 API
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="内置浏览器" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>垂直 + 水平标签页</h3>
侧边栏显示 git 分支、关联 PR 状态/编号、工作目录、监听端口和最新通知文本。支持水平和垂直分割。
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="垂直标签页和分割窗格" width="100%" />
</td>
</tr>
</table>

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

主要新增的是侧边栏和通知系统。侧边栏有垂直标签页，显示每个工作区的 git 分支、关联 PR 状态/编号、工作目录、监听端口和最新通知文本。通知系统能捕获终端序列（OSC 9/99/777），并提供 CLI（`cmux notify`），您可以将其接入 Claude Code、OpenCode 等代理的钩子。当代理等待时，其窗格会显示蓝色光环，标签页会在侧边栏高亮，这样我就能在多个分割窗格和标签页之间一眼看出哪个需要我。⌘⇧U 可以跳转到最新的未读通知。

内置浏览器拥有从 [agent-browser](https://github.com/vercel-labs/agent-browser) 移植的可脚本化 API。代理可以抓取无障碍树快照、获取元素引用、执行点击、填写表单和执行 JS。您可以在终端旁边分割出浏览器窗格，让 Claude Code 直接与您的开发服务器交互。

所有操作都可以通过 CLI 和 socket API 进行脚本化 — 创建工作区/标签页、分割窗格、发送按键、在浏览器中打开 URL。

## The Zen of cmux

cmux 不规定开发者应该如何使用工具。它是一个带有 CLI 的终端和浏览器，其余的由你决定。

cmux 是原语，而非解决方案。它提供终端、浏览器、通知、工作区、分割、标签页，以及控制这一切的 CLI。cmux 不强迫你以特定方式使用编程代理。你用这些原语构建什么，完全取决于你自己。

最优秀的开发者一直在构建自己的工具。还没有人找到与代理协作的最佳方式，那些构建封闭产品的团队也没有找到。最接近自己代码库的开发者会最先找到答案。

给一百万个开发者可组合的原语，他们会比任何自上而下设计的产品团队更快地找到最高效的工作流。

## 文档

有关 cmux 配置的更多信息，请[查看我们的文档](https://cmux.com/docs/getting-started?utm_source=readme)。

## 键盘快捷键

### 工作区

| 快捷键 | 操作 |
|----------|--------|
| ⌘ N | 新建工作区 |
| ⌘ 1–8 | 跳转到工作区 1–8 |
| ⌘ 9 | 跳转到最后一个工作区 |
| ⌃ ⌘ ] | 下一个工作区 |
| ⌃ ⌘ [ | 上一个工作区 |
| ⌘ ⇧ W | 关闭工作区 |
| ⌘ ⇧ R | 重命名工作区 |
| ⌘ B | 切换侧边栏 |

### 界面

| 快捷键 | 操作 |
|----------|--------|
| ⌘ T | 新建界面 |
| ⌘ ⇧ ] | 下一个界面 |
| ⌘ ⇧ [ | 上一个界面 |
| ⌃ Tab | 下一个界面 |
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
| ⌘ ⇧ H | 闪烁聚焦面板 |

### 浏览器

浏览器开发者工具快捷键遵循 Safari 默认设置，可在`设置 → 键盘快捷键`中自定义。

| 快捷键 | 操作 |
|----------|--------|
| ⌘ ⇧ L | 在分割中打开浏览器 |
| ⌘ L | 聚焦地址栏 |
| ⌘ [ | 后退 |
| ⌘ ] | 前进 |
| ⌘ R | 刷新页面 |
| ⌥ ⌘ I | 切换开发者工具（Safari 默认） |
| ⌥ ⌘ C | 显示 JavaScript 控制台（Safari 默认） |

### 通知

| 快捷键 | 操作 |
|----------|--------|
| ⌘ I | 显示通知面板 |
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
| ⌘ ⇧ , | 重新加载配置 |
| ⌘ Q | 退出 |

## 每夜构建

[下载 cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY 是一个拥有独立 Bundle ID 的单独应用，因此可以与稳定版并行运行。它从最新的 `main` 提交自动构建，并通过独立的 Sparkle 更新源自动更新。

## 会话恢复（当前行为）

重新启动时，cmux 目前仅恢复应用布局和元数据：
- 窗口/工作区/窗格布局
- 工作目录
- 终端回滚缓冲区（尽力恢复）
- 浏览器 URL 和导航历史

cmux **不会**恢复终端应用内部的实时进程状态。例如，活动的 Claude Code/tmux/vim 会话在重启后尚无法恢复。

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## 参与贡献

参与方式：

- 在 X 上关注我们：[@manaflowai](https://x.com/manaflowai)、[@lawrencecchen](https://x.com/lawrencecchen)、[@austinywang](https://x.com/austinywang)
- 加入 [Discord](https://discord.gg/xsgFEVrWCZ) 讨论
- 创建和参与 [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) 和[讨论](https://github.com/manaflow-ai/cmux/discussions)
- 告诉我们您在用 cmux 构建什么

## 社区

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux 免费、开源，并将一直如此。如果您想支持开发并提前体验即将推出的功能：

**[获取 Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **功能请求/Bug 修复优先处理**
- **抢先体验：为每个工作区、标签页和面板提供上下文的 cmux AI**
- **抢先体验：桌面与手机间终端同步的 iOS 应用**
- **抢先体验：云端虚拟机**
- **抢先体验：语音模式**
- **我的个人 iMessage/WhatsApp**

## 许可证

cmux 以 [AGPL-3.0-or-later](LICENSE) 开源。

如果您的组织无法遵守 AGPL，可提供商业许可证。详情请联系 [founders@manaflow.com](mailto:founders@manaflow.com)。
