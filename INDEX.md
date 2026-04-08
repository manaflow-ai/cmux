# cmux Codebase Index

> Fork: aryateja2106/cmux | Upstream: manaflow-ai/cmux
> Swift macOS terminal multiplexer with Ghostty, browser panes, SSH remote workspaces

## Quick Start

```bash
./scripts/setup.sh                           # Init submodules + build GhosttyKit
./scripts/reload.sh --tag my-feature         # Build Debug app
./scripts/reload.sh --tag my-feature --launch # Build + launch
```

## Architecture Overview

```
cmux (macOS App)
  |-- Ghostty (Zig) -----> Terminal rendering (Metal)
  |-- WKWebView ----------> Browser panes (SSH proxy routing)
  |-- Bonsplit -----------> Tab/split pane management
  |-- Socket API ---------> CLI control (v1 text + v2 JSON-RPC)
  |-- Remote Daemon (Go) -> SSH session proxy (SOCKS5/CONNECT)
```

## Directory Map

### Core Application (`Sources/`)

| File | Purpose |
|------|---------|
| `cmuxApp.swift` | SwiftUI app entry point, settings |
| `AppDelegate.swift` | Window lifecycle, key events, socket server |
| `ContentView.swift` | Main window: sidebar + workspace |
| `Workspace.swift` | Core workspace model, panes, remote sessions, proxy |
| `TabManager.swift` | Workspace/tab collection manager |
| `TerminalController.swift` | Terminal session lifecycle |
| `TerminalView.swift` | SwiftUI terminal wrapper |
| `GhosttyTerminalView.swift` | AppKit/Ghostty integration |
| `CmuxConfig.swift` | Settings file parser (~/.config/cmux/settings.json) |
| `SessionPersistence.swift` | Save/restore state across restarts |
| `PortScanner.swift` | Detect listening ports |

### Panels (`Sources/Panels/`)

| File | Purpose |
|------|---------|
| `Panel.swift` | Base panel protocol |
| `TerminalPanel.swift` | Terminal panel model |
| `BrowserPanel.swift` | Browser panel: WKWebView, SSH proxy, cookies |
| `BrowserPanelView.swift` | Browser UI: omnibar, devtools, navigation |
| `BrowserPopupWindowController.swift` | Popup window handling |
| `CmuxWebView.swift` | WKWebView wrapper + navigation delegate |
| `MarkdownPanel.swift` | Markdown viewer panel |

### SSH & Remote (`Sources/` + `daemon/`)

| File | Purpose |
|------|---------|
| `Sources/TerminalSSHSessionDetector.swift` | Detect SSH sessions, SCP file drops |
| `Sources/TerminalImageTransfer.swift` | Image upload over SSH |
| `Sources/RemoteRelayZshBootstrap.swift` | Shell bootstrap for remote sessions |
| `Sources/Panels/BrowserPanel.swift` | SSH SOCKS5 proxy for browser panes |
| `daemon/remote/cmd/cmuxd-remote/main.go` | Remote daemon entry point |
| `daemon/remote/cmd/cmuxd-remote/cli.go` | CLI relay table mapper |
| `daemon/remote/cmd/cmuxd-remote/agent_launch.go` | Remote agent bootstrap |

### Browser Features (`Sources/Panels/` + `Sources/Find/`)

| File | Purpose |
|------|---------|
| `BrowserPanel.swift` | Core browser: proxy config, cookie isolation, search engines |
| `BrowserPanelView.swift` | UI: omnibar, progress, devtools toggle |
| `BrowserPopupWindowController.swift` | window.open() popup handling |
| `BrowserSearchOverlay.swift` | Find-in-page UI |
| `BrowserFindJavaScript.swift` | Find JavaScript injection |
| `CmuxWebView.swift` | Custom WKWebView with navigation delegate |

### Window & UI (`Sources/`)

| File | Purpose |
|------|---------|
| `WindowAccessor.swift` | macOS window utilities |
| `WindowDecorationsController.swift` | Titlebar and window chrome |
| `WindowToolbarController.swift` | App menu and toolbar |
| `WindowDragHandleView.swift` | Custom drag handle |
| `TerminalWindowPortal.swift` | AppKit portal for Ghostty NSView |
| `BrowserWindowPortal.swift` | AppKit portal for WKWebView |
| `NotificationsPage.swift` | Notification UI |
| `SidebarSelectionState.swift` | Sidebar selection state |

### CLI (`CLI/`)

| File | Purpose |
|------|---------|
| `cmux.swift` | CLI entry point, socket commands, v1+v2 protocol |

### Remote Daemon (`daemon/remote/`)

| File | Purpose |
|------|---------|
| `cmd/cmuxd-remote/main.go` | Entry point, stream RPC server |
| `cmd/cmuxd-remote/cli.go` | CLI relay (busybox-style) |
| `cmd/cmuxd-remote/agent_launch.go` | Remote agent bootstrap |
| `cmd/cmuxd-remote/tmux_compat.go` | tmux-compatible geometry |

### Skills (Agent Automation)

| Directory | Purpose |
|-----------|---------|
| `skills/cmux/` | Core topology control (windows, workspaces, panes) |
| `skills/cmux-browser/` | Browser automation (navigate, screenshot, fill, wait) |
| `skills/cmux-markdown/` | Markdown viewer automation |
| `skills/cmux-debug-windows/` | Debug window helpers |
| `skills/release/` | Release process automation |

### Build System

| File | Purpose |
|------|---------|
| `Package.swift` | SPM manifest (SwiftTerm dep) |
| `GhosttyTabs.xcodeproj/` | Xcode project |
| `scripts/setup.sh` | Init submodules + build GhosttyKit |
| `scripts/reload.sh` | Build Debug app (tagged) |
| `scripts/reloadp.sh` | Build + launch Release app |
| `scripts/rebuild.sh` | Clean rebuild |
| `scripts/bump-version.sh` | Version management |

### Submodules

| Path | Repo | Purpose |
|------|------|---------|
| `ghostty/` | manaflow-ai/ghostty | Terminal emulator (Zig) |
| `vendor/bonsplit/` | manaflow-ai/bonsplit | Tab/split pane library |
| `homebrew-cmux/` | manaflow-ai/homebrew-cmux | Homebrew formula |

### Documentation (`docs/`)

| File | Purpose |
|------|---------|
| `v2-api-migration.md` | Socket API v1 -> v2 migration spec |
| `remote-daemon-spec.md` | SSH remote daemon architecture |
| `ghostty-fork.md` | Ghostty fork changes vs upstream |
| `notifications.md` | Notification system architecture |
| `agent-browser-port-spec.md` | Browser automation parity spec |
| `socket-focus-steal-audit.todo.md` | Focus policy audit |

### Tests

| Directory | Framework | Purpose |
|-----------|-----------|---------|
| `tests/` | Python (v1 text protocol) | Legacy socket tests |
| `tests_v2/` | Python (v2 JSON-RPC) | Current socket tests |
| `cmuxTests/` | Swift XCTest | Unit tests |
| `cmuxUITests/` | Swift XCUITest | UI tests |

### Web (`web/`)

Next.js marketing site (deployed to Vercel)

## Key Architectural Patterns

- **Panel types**: Terminal (Ghostty), Browser (WKWebView), Markdown
- **Remote proxy**: SOCKS5/HTTP CONNECT per SSH transport, shared endpoint
- **Browser isolation**: Workspace-scoped WKWebsiteDataStore
- **Socket API**: Unix socket, v2 JSON-RPC (replacing v1 text)
- **Focus policy**: Non-focus-intent socket commands preserve user focus
- **Typing latency**: Direct AppKit event routing, no SwiftUI in hot path
- **Localization**: String(localized:) mandatory, translations in .xcstrings

## VNC/Remote Desktop Status

**Not implemented.** Remote access is SSH-only (terminal + browser proxy).
Opportunity: Add RealVNC support for graphical remote desktop access.
