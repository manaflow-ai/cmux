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

**Homebrew:**

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Or [download the DMG](https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg) directly.

## Why cmux?

Running multiple AI coding agents? cmux helps you manage them. Instead of losing track of which terminal needs input, the notification panel shows you exactly where to look.

A native macOS app means it launches instantly, uses minimal RAM, and feels right at home on your Mac.
