> 此翻译由 Claude 生成。如有改进建议，欢迎提交 PR。

<h1 align="center">cmux</h1>
<p align="center">基于 Ghostty 的 macOS 终端，带有垂直标签页和为 AI 编程代理设计的通知系统</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="下载 cmux macOS 版" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
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
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> 为远程机器创建工作区。浏览器窗格通过远程网络路由，因此 localhost 直接可用。将图片拖入远程会话即可通过 scp 上传。
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> 一条命令运行 Claude Code 的队友模式。队友以原生分割的形式生成，侧边栏显示元数据和通知。无需 tmux。
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **浏览器导入** — 从 Chrome、Firefox、Arc 及 20 多种浏览器导入 Cookie、历史记录和会话，让浏览器窗格启动即已登录
- **自定义命令** — 在 [`cmux.json`](https://cmux.com/docs/custom-commands) 中定义项目专属操作，通过命令面板启动
- **可脚本化** — 通过 CLI 和 socket API 创建工作区、分割窗格、发送按键和自动化浏览器操作
- **原生 macOS 应用** — 使用 Swift 和 AppKit 构建，非 Electron。启动快速，内存占用低。
- **兼容 Ghostty** — 读取您现有的 `~/.config/ghostty/config` 配置文件中的主题、字体和颜色设置
- **GPU 加速** — 由 libghostty 驱动，渲染流畅
- **键盘快捷键** — 为工作区、分割、浏览器等提供[丰富的快捷键](https://cmux.com/docs/keyboard-shortcuts)
- **开源** — 免费且采用 GPL 许可

## 安装

### DMG（推荐）

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="下载 cmux macOS 版" width="180" />
</a>

打开 `.dmg` 文件并将 cmux 拖动到"应用程序"文件夹。cmux 通过 Sparkle 自动更新，您只需下载一次。

### Homebrew

```bash
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

主要新增的是侧边栏和通知系统。侧边栏有垂直标签页，显示每个工作区的 git 分支、关联 PR 状态/编号、工作目录、监听端口和最新通知文本。通知系统能捕获终端序列（OSC 9/99/777），并提供 CLI（`cmux notify`），您可以将其接入 Claude Code、OpenCode 等代理的钩子。当代理等待时，其窗格会显示蓝色光环，标签页会在侧边栏高亮，这样我就能在多个分割窗格和标签页之间一眼看出哪个需要我。Cmd+Shift+U 可以跳转到最新的未读通知。

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
| ⌥ ⌘ E | 编辑工作区描述 |
| ⌘ B | 切换侧边栏 |
| ⌥ ⌘ B | 切换右侧边栏 |
| ⌘ ⇧ E | 切换右侧边栏焦点 |

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

浏览器开发者工具快捷键遵循 Safari 默认设置，可在 `设置 → 键盘快捷键` 中自定义。
命令面板导航快捷键（包括 ⌃ P）同样可自定义，并可清除以便按键传递到活动终端。

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
| ⌥ ⌘ U | 切换当前项的未读状态 |
| ⌃ ⌘ U | 将当前项标记为最早未读并跳转到下一个最新未读 |

### 查找

| 快捷键 | 操作 |
|----------|--------|
| ⌘ F | 查找 |
| ⌘ ⇧ F | 在目录中查找 |
| ⌘ G / ⌥ ⌘ G | 查找下一个 / 上一个 |
| ⌥ ⌘ ⇧ F | 隐藏查找栏 |
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
| ⌘ ⇧ O | 重新打开上一个会话 |
| ⌘ , | 设置 |
| ⌘ ⇧ , | 重新加载配置 |
| ⌘ Q | 退出 |

## 每夜构建

[下载 cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY 是一个拥有独立 Bundle ID 的单独应用，因此可以与稳定版并行运行。它从最新的 `main` 提交自动构建，并通过独立的 Sparkle 更新源自动更新。

在 [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) 或 [Discord 的 #nightly-bugs 频道](https://discord.gg/xsgFEVrWCZ) 上报告每夜构建的 bug。

## 会话恢复

退出 cmux 会保存当前会话。重新启动时，cmux 会恢复应用管理的状态：
- 窗口/工作区/窗格布局
- 工作目录
- 终端回滚缓冲区（尽力恢复）
- 浏览器 URL 和导航历史

cmux 不会为任意实时进程状态做检查点。tmux、vim、shell 和不支持的终端应用会作为普通终端重新打开。

当 hooks 保存了原生会话 ID 时，受支持的 agent 会话可以恢复。请在安装 agent CLI 之后再安装 hooks，以确保其二进制文件位于 `PATH` 上：

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` 会安装它能找到的受支持 agent，并为跳过的 agent 打印摘要。受支持的恢复集成包括 Claude Code、Codex、Grok、OpenCode、Pi、Amp、Cursor CLI、Gemini、Rovo Dev、Copilot、CodeBuddy、Factory 和 Qoder。当在设置中启用了 Claude 集成时，Claude Code 由 cmux Claude wrapper 处理。

高级用户和集成可以把自定义恢复命令绑定到当前终端 surface。这适用于 tmux 会话或自定义 agent CLI 等拥有持久状态的工具：

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

这个绑定会继续关联到 cmux surface。通过公开 CLI 或 socket 创建的绑定会保存用于检查和手动恢复，除非您为某个签名命令前缀批准了自动恢复。已批准的前缀还会绑定到工作目录和确切的环境变量值（如果存在）。可在 **设置 > 终端 > 恢复命令** 中查看或编辑批准项。cmux 只会自动运行它标记为可信的恢复绑定，例如从运行中进程检测到的 tmux 绑定或用户批准的前缀。令牌、密码、密钥和 API key 等敏感环境变量键会在保存恢复绑定前被丢弃。

如需让恢复的 agent 终端保持空闲，而不是自动运行其恢复命令，请关闭 **设置 > 终端 > 重新打开时恢复 Agent 会话**，或在 `~/.config/cmux/cmux.json` 中设置：

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

这只会禁用自动的 agent 恢复命令。cmux 仍会恢复保存的布局、工作目录、回滚缓冲区和浏览器历史。

如果您需要手动重新应用上次保存的快照，请使用：
- `文件 > 重新打开上一个会话`
- `⌘ ⇧ O`
- `cmux restore-session`

在底层，cmux 会在 `~/Library/Application Support/cmux/` 下写入带版本的快照，agent hooks 会在 `~/.cmuxterm/` 下写入会话映射。恢复时，cmux 会先重建布局，然后在启用了自动 agent 恢复时运行受支持 agent 的原生恢复命令。

完整指南请见 <https://cmux.com/docs/session-restore>。

## FAQ

### cmux 与 Ghostty 是什么关系？

cmux 不是 Ghostty 的分支。它把 [libghostty](https://github.com/ghostty-org/ghostty) 作为库用于终端渲染，就像应用使用 WebKit 来呈现网页视图一样。Ghostty 是一个独立的终端；cmux 是构建在其渲染引擎之上的另一款应用。

### 它支持哪些平台？

目前仅支持 macOS。cmux 是一个原生的 Swift + AppKit 应用。

### 有 iOS 应用吗？

有，目前处于测试阶段。在 Mobile Connect 窗口中将您的 iPhone 与 Mac 配对，即可从手机连接到您的终端，并可选择转发终端通知。它以 cmux BETA 的形式通过 TestFlight 发布。请参阅 [iOS 文档](https://cmux.com/docs/ios)。

### cmux 支持哪些编程代理？

全部支持。cmux 是一个终端，因此任何能在终端中运行的代理都开箱即用：Claude Code、Codex、OpenCode、Gemini CLI、Kiro、Aider、Goose、Amp、Cline、Cursor Agent，以及任何其他可从命令行启动的工具。

### cmux 能编排多个代理和子代理吗？

可以。当某个代理生成子代理或队友时，cmux 会把它们变成原生窗格和分割，而不是隐藏的后台进程。它支持 [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) 和 [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) 的多模型编排，因此一次运行中的每个代理都可见、可控。

### 我可以用 cmux 操作远程机器吗？

可以。通过 SSH 打开工作区并连接到远程 tmux 会话，这样代理可以在远程主机上运行，而您从 cmux 来驱动它们。请参阅 [SSH 和远程](https://cmux.com/docs/ssh)。

### 通知是如何工作的？

当某个进程需要关注时，cmux 会在窗格周围显示通知提示环、在侧边栏显示未读徽章、弹出通知气泡，以及 macOS 桌面通知。这些会通过标准终端转义序列（OSC 9/99/777）自动触发，您也可以用 [cmux CLI](https://cmux.com/docs/notifications#cli-usage) 和 [agent hooks](https://cmux.com/docs/notifications#integration-examples) 来触发它们。任何支持 hooks 或 OSC 的代理都可使用，包括 Claude Code、Codex、OpenCode 和 pi。

### cmux 可编程吗？

可以。每个操作都可通过 cmux CLI 和 Unix socket 使用：创建工作区、打开分割窗格、发送输入、读取屏幕内容、截图，以及驱动内置浏览器。请参阅 [CLI 参考](https://cmux.com/docs/api) 和 [浏览器自动化](https://cmux.com/docs/browser-automation) 文档。

### 内置浏览器能做什么？

cmux 可以在终端旁边分割出一个真正的浏览器窗格，并且它完全可编程：导航、抓取 DOM 快照、点击、输入、执行 JavaScript，以及通过同一套 socket API 读取控制台和网络活动。代理用它来验证自己做的网页改动，而无需离开 cmux。请参阅 [浏览器自动化](https://cmux.com/docs/browser-automation)。

### cmux 有 skills 吗？

有。Skills 是可复用的工作流，您可以将其交给任何运行在 cmux 中的代理，用于诸如 CLI 控制、工作区自动化、设置和浏览器界面等任务。可在 [cmux-skills](https://github.com/manaflow-ai/cmux-skills) 浏览开放的合集，或阅读 [skills 文档](https://cmux.com/docs/skills)。

### 我可以自定义键盘快捷键吗？

终端键绑定从您的 Ghostty 配置文件（`~/.config/ghostty/config`）中读取。cmux 专属的快捷键（工作区、分割、浏览器、通知）可在设置中自定义。完整列表请参阅 [默认快捷键](https://cmux.com/docs/keyboard-shortcuts)。

### 我可以自定义 cmux 吗？

可以。终端渲染使用您的 Ghostty 配置，因此主题、字体、颜色和光标会直接沿用。cmux 自己在 `~/.config/cmux/cmux.json` 中的设置控制侧边栏、标签栏、分割窗格和行为，并且每个[键盘快捷键](https://cmux.com/docs/keyboard-shortcuts)都可编辑。请参阅 [配置](https://cmux.com/docs/configuration)。

### 我的会话会被保存吗？

会。cmux 在重新启动时会恢复您的窗口、工作区、窗格、工作目录和回滚缓冲区，并且这些状态能在整机重启后保留，而不仅仅是退出应用。像 Claude Code、Codex 和 OpenCode 这样的 agent 会话也会回来。请参阅 [会话恢复](https://cmux.com/docs/session-restore)。

### 它与 tmux 相比如何？

tmux 是一个在任意终端内运行的终端复用器。cmux 是一个带 GUI 的原生 macOS 应用：垂直标签页、分割窗格、内嵌浏览器和 socket API，全部内置，无需配置文件或前缀键。也就是说，很多人乐于把 cmux 与 SSH 和 tmux 一起使用，而 cmux 可以原生连接到您的远程 tmux 会话（[测试版](https://cmux.com/docs/remote-tmux)）。

### cmux 免费吗？

是的，cmux 免费使用。源代码可在 [GitHub](https://github.com/manaflow-ai/cmux) 上获取。

### 我如何支持 cmux？

cmux 免费且开源，并将一直如此。如果您想支持开发并提前体验接下来的功能，包括 cmux AI、iOS 应用和 Cloud VMs，请查看 [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)。

### 我有功能请求或发现了 bug？

我们很想听到。请在 GitHub 上提交 [issue](https://github.com/manaflow-ai/cmux/issues) 或 [pull request](https://github.com/manaflow-ai/cmux/pulls)，或者 [给我们发邮件](mailto:founders@manaflow.com?subject=cmux%20feature%20request)。

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

cmux 以 [GPL-3.0-or-later](LICENSE) 开源。

如果您的组织无法遵守 GPL，可提供商业许可证。详情请联系 [founders@manaflow.com](mailto:founders@manaflow.com)。
