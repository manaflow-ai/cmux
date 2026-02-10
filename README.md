<h1 align="center">cmux</h1>
<p align="center">A Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux screenshot" width="900" />
</p>

## Features

- **Native macOS app** — Built with Swift and AppKit, not Electron. Fast startup, low memory.
- **Vertical tabs** — See all your terminals at a glance in a sidebar
- **Notification panel** — See which agents are waiting for input at a glance
- **Notification rings** — Tabs flash when AI agents (Claude Code, Codex) need your attention
- **Lightweight** — Small binary, minimal resource footprint. No bundled browser engine.
- **GPU-accelerated** — Powered by libghostty for smooth rendering

## Install

### DMG (recommended)

[![Download for Mac](web/public/download-badge.svg)](https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg)

Open the `.dmg` and drag cmux to your Applications folder. cmux auto-updates via Sparkle, so you only need to download once.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

To update later:

```bash
brew upgrade --cask cmux
```

On first launch, macOS may ask you to confirm opening an app from an identified developer. Click **Open** to proceed.

## Why cmux?

Running multiple AI coding agents? cmux helps you manage them. Instead of losing track of which terminal needs input, the notification panel shows you exactly where to look.

A native macOS app means it launches instantly, uses minimal RAM, and feels right at home on your Mac.

## Keyboard Shortcuts

### Workspaces

| Shortcut | Action |
|----------|--------|
| ⌘ N | New workspace |
| ⌘ 1–8 | Jump to workspace 1–8 |
| ⌘ 9 | Jump to last workspace |
| ⌘ ⇧ W | Close workspace |

### Surfaces

| Shortcut | Action |
|----------|--------|
| ⌘ T | New surface |
| ⌘ ⇧ [ | Previous surface |
| ⌃ ⇧ Tab | Previous surface |
| ⌃ 1–8 | Jump to surface 1–8 |
| ⌃ 9 | Jump to last surface |
| ⌘ W | Close surface |

### Split Panes

| Shortcut | Action |
|----------|--------|
| ⌘ D | Split right |
| ⌘ ⇧ D | Split down |
| ⌥ ⌘ ← → ↑ ↓ | Focus pane directionally |

### Browser

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ B | Open browser in split |
| ⌘ L | Focus address bar |
| ⌘ ] | Forward |
| ⌘ R | Reload page |
| ⌥ ⌘ I | Open Developer Tools |

### Notifications

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ I | Show notifications panel |
| ⌘ ⇧ U | Jump to latest unread |

### Find

| Shortcut | Action |
|----------|--------|
| ⌘ F | Find |
| ⌘ G / ⌘ ⇧ G | Find next / previous |
| ⌘ ⇧ F | Hide find bar |
| ⌘ E | Use selection for find |

### Terminal

| Shortcut | Action |
|----------|--------|
| ⌘ K | Clear scrollback |
| ⌘ C | Copy (with selection) |
| ⌘ V | Paste |
| ⌘ + / ⌘ - | Increase / decrease font size |
| ⌘ 0 | Reset font size |

### Window

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ N | New window |
| ⌘ , | Settings |
| ⌘ ⇧ R | Reload configuration |
| ⌘ Q | Quit |
