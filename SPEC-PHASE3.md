# SPEC: Phase 3 — arya-cmux Agent Host Platform

> **Goal**: Turn arya-cmux into a Mac mini-centric agent host with VNC remote desktop, SSH reliability, mobile-ready architecture, and AVM security runtime foundations.
> **Owner**: aryateja | **Fork**: aryateja2106/cmux | **Base**: manaflow-ai/cmux
> **Date**: 2026-04-06

---

## Context

arya-cmux is a fork of cmux (Swift macOS terminal multiplexer) with:
- RoyalVNCKit integrated (VNC panel — connection working, framebuffer rendering confirmed)
- Monochrome dark theme (LeTerminal aesthetic)
- Rebranded to "arya-cmux DEV" with isolated bundle ID

The larger product vision is a **Mac mini-centric agent host platform** — an "Apple AI OS" that lets users securely build, run, and serve AI agents from Mac mini hardware, with mobile access from iPhone/iPad. Think: cmux terminal + exo compute cluster + Manus-style mobile agent viewer.

---

## Phase 3A: VNC Panel Polish (Priority: HIGH)

### 3A.1 Fix VNC Connection UX
**Status**: Connection works but UX needs polish

- [ ] Fix port display — currently shows "5,900" due to SwiftUI locale formatting. Use `String(port)` explicitly in all Text views
- [ ] Pre-fill username with `NSUserName()` (dynamic, not hardcoded)
- [ ] Add "Connecting..." spinner with timeout (30s default, configurable)
- [ ] Show detailed error messages when connection fails (auth type mismatch, network unreachable, timeout)
- [ ] Add "Disconnect" button when connected
- [ ] Add reconnect button after disconnection
- [ ] Show connection duration in tab title

### 3A.2 Mouse & Keyboard Input
**Status**: VNCCAFramebufferView from RoyalVNCKit handles this natively

- [ ] Verify mouse movement tracking works in VNCCAFramebufferView
- [ ] Verify left/right/middle click forwarding
- [ ] Verify scroll wheel forwarding
- [ ] Verify keyboard input (key down/up events)
- [ ] Test modifier keys (Cmd, Ctrl, Alt, Shift)
- [ ] Test special keys (F1-F12, arrows, Home/End, Delete, Escape)
- [ ] Add Ctrl+Alt+Del send button in toolbar (for Windows VMs)
- [ ] Handle keyboard focus properly — VNCCAFramebufferView should capture keys when focused

### 3A.3 Display Quality
- [ ] Implement scaling modes: Fit to Window (default), 1:1, Custom Zoom
- [ ] Add display quality selector (color depth: 8/16/24-bit, compression level)
- [ ] Handle server resolution changes (ExtendedDesktopSize encoding)
- [ ] Support retina/HiDPI scaling correctly

### 3A.4 Clipboard
- [ ] Verify bidirectional clipboard works (RoyalVNCKit has `isClipboardRedirectionEnabled: true`)
- [ ] Test copy text from remote -> paste locally
- [ ] Test copy text from local -> paste remotely

### 3A.5 Session Management
- [ ] Save VNC connections in Keychain (host, port, username — password in Keychain)
- [ ] Remember last-used connections
- [ ] Persist VNC tabs across app restarts
- [ ] Connection profiles (saved server configs with names)

---

## Phase 3B: SSH Session Reliability (Priority: HIGH)

### Known Issues
- SSH sessions in cmux have input lag and command display issues
- Commands not rendering clearly when connected to Raspberry Pi
- SSH session drops without clean reconnection

### 3B.1 SSH Input Fixes
- [ ] Audit `TerminalSSHSessionDetector.swift` for input handling issues
- [ ] Test SSH to Raspberry Pi — verify echo, cursor position, backspace behavior
- [ ] Check terminal encoding (UTF-8) is set correctly for SSH sessions
- [ ] Verify TERM environment variable is set properly for remote sessions
- [ ] Test with different shell types (bash, zsh, fish) on remote hosts

### 3B.2 SSH Reconnection
- [ ] Implement auto-reconnect on SSH session drop
- [ ] Show "Reconnecting..." status in tab title
- [ ] Preserve scrollback on reconnect
- [ ] Support SSH ControlMaster for connection multiplexing

### 3B.3 SSH + VNC Integration
- [ ] `cmux ssh user@host --vnc` — auto-forward VNC port through SSH tunnel
- [ ] Detect VNC server on remote host (check ports 5900-5910)
- [ ] Open VNC panel that routes through cmux's SSH SOCKS proxy
- [ ] Show both terminal and VNC side-by-side for same remote host

---

## Phase 3C: CLI Commands (Priority: MEDIUM)

### 3C.1 VNC CLI
- [ ] `cmux vnc <host>:<port>` — open VNC panel in focused pane
- [ ] `cmux vnc --split <host>:<port>` — open as split pane
- [ ] `cmux vnc list` — list active VNC connections
- [ ] `cmux vnc disconnect <surface>` — disconnect VNC session
- [ ] `cmux vnc screenshot <surface> --out <path>` — capture framebuffer as PNG

### 3C.2 Socket API (v2 JSON-RPC)
- [ ] `vnc.connect { hostname, port, username }` — create VNC panel
- [ ] `vnc.disconnect { surface_id }` — close VNC connection
- [ ] `vnc.status { surface_id }` — get connection state
- [ ] `vnc.screenshot { surface_id }` — capture framebuffer

---

## Phase 3D: AVM Security Runtime Foundation (Priority: MEDIUM)

### Vision
AVM (Agent Virtual Machine) = a local runtime daemon that all AI agents run through.
Think: "V8 for agents" — resource caps, egress control, PII detection, kill switch.

### 3D.1 avmd Daemon (Rust or Swift)
- [ ] Create `avmd` daemon that listens on Unix domain socket
- [ ] Agent registry: track spawned agent processes (PID, name, resource usage)
- [ ] Policy file: `~/.hyperspace/avm-policy.json`
  - Resource caps (CPU time, RSS memory, address space)
  - Network policy (allowed/blocked domains)
  - PII/credential detection patterns
  - Action per category: `block`, `ask`, `warn`
- [ ] Resource governor: `setrlimit` for CPU/RSS per agent process
- [ ] Periodic sampler: read CPU/RAM via `task_info` (macOS)
- [ ] Kill switch: SIGSTOP/SIGKILL agents exceeding limits

### 3D.2 Network Egress Control
- [ ] HTTP(S) proxy inside avmd
- [ ] Set `HTTP_PROXY`/`HTTPS_PROXY` for agent shells
- [ ] Log all outbound requests (URL, headers, redacted body)
- [ ] PII/credential regex detection (emails, card numbers, AWS keys, token prefixes)
- [ ] Domain allow/deny list
- [ ] `ask` mode: pause request, prompt user in cmux

### 3D.3 Command Approval
- [ ] `avm-sh` wrapper for dangerous commands
- [ ] Detect: `rm -rf /`, `curl | sh`, `chmod 777`, etc.
- [ ] Pause and prompt user for approval (30s timeout, auto-deny)
- [ ] Log all blocked/approved commands

### 3D.4 CMUX Integration
- [ ] Agent panes launched via avmd instead of raw shell
- [ ] AVM status indicators on each tab (safe/warning/blocked)
- [ ] `avm top` command — shows processes, CPU/RAM, security events
- [ ] Dedicated AVM sidebar section in cmux

---

## Phase 3E: Mobile Architecture Planning (Priority: LOW — Design Only)

### Vision
Mobile app (iOS/iPadOS) that lets you:
- View agent activity in real time (like Manus mobile — timeline + media viewer)
- Control VNC sessions with touch gestures
- Approve/deny agent actions (AVM prompts)
- Monitor resource usage across all Mac mini hosts

### 3E.1 Mobile VNC Touch Mapping
- Tap = left click
- Long press = right click
- Two-finger tap = middle click
- Pinch-to-zoom = framebuffer scaling
- Two-finger scroll = mouse scroll
- Edge swipe = special keys panel (Ctrl, Alt, Esc, F-keys)
- Trackpad mode (two-finger drag = mouse movement)

### 3E.2 Mobile Agent Dashboard
- Host list (Mac minis on Tailscale/local network)
- Per-host workspace list (VMs, terminal sessions, VNC connections)
- Agent activity timeline (what each agent is doing, with screenshots)
- "Jump to live" scrubber (like Manus mobile UI)
- Push notifications for agent completions, approvals needed, errors

### 3E.3 Architecture
- Shared Swift code between macOS host app and iOS client
- Communication: cmux socket API over Tailscale/SSH tunnel
- WebRTC for low-latency VNC streaming to mobile
- SwiftUI for cross-platform UI components

---

## Build & Test

### Prerequisites
```bash
brew install zig          # Already installed (0.15.2)
brew install zls          # Already installed (0.15.1)
```

### Build Commands
```bash
cd ~/ZenflowProjects/cmux
pkill -9 -f "cmux DEV"                        # Kill old instances
./scripts/reload.sh --tag arya-vnc --launch    # Build + launch
# Note: reload.sh kill pattern doesn't match renamed app, always pkill first
```

### VNC Testing
1. Enable macOS Remote Management: System Settings > Sharing > Remote Management
2. Verify port 5900 is listening: `netstat -an | grep 5900`
3. Open arya-cmux DEV > Cmd+Shift+P > "vnc" > "New Tab (VNC Remote Desktop)"
4. Enter host/port/user/pass > Connect
5. VNC always shows the **active console session** (whoever is at the display), not per-user sessions

### SSH Testing
1. SSH to Raspberry Pi: `cmux ssh pi@<ip>`
2. Verify command input/output renders correctly
3. Test with: `ls`, `top`, `vim`, `htop`
4. Test reconnect: disconnect network, verify auto-reconnect

---

## Key Files

### VNC Panel (New)
```
Sources/Panels/VNCPanel.swift          — Panel model, VNCConnectionDelegate
Sources/Panels/VNCPanelView.swift      — SwiftUI view, connection form, NSViewRepresentable
```

### Modified for VNC
```
Sources/Panels/Panel.swift             — Added .vnc to PanelType
Sources/Panels/PanelContentView.swift  — Added .vnc dispatch
Sources/Workspace.swift                — newVNCSurface(), installVNCPanelSubscription()
Sources/TabManager.swift               — openVNC()
Sources/ContentView.swift              — Command palette entry + handler
Package.swift                          — RoyalVNCKit dependency
GhosttyTabs.xcodeproj                  — File refs, SPM package, build phases
```

### SSH (Existing — to fix)
```
Sources/TerminalSSHSessionDetector.swift  — SSH detection, SCP file drops
Sources/TerminalImageTransfer.swift       — Image upload over SSH
Sources/RemoteRelayZshBootstrap.swift     — Shell bootstrap for remote sessions
Sources/Panels/BrowserPanel.swift         — SSH SOCKS proxy for browser panes
daemon/remote/cmd/cmuxd-remote/           — Go remote daemon
```

### Theme
```
~/.config/ghostty/config               — Monochrome dark theme
Sources/ContentView.swift               — Accent color (#b4b4b4 gray)
Sources/cmuxApp.swift                   — App name "arya-cmux"
```

---

## Dependencies
- **RoyalVNCKit** v1.1.0 (MIT) — github.com/royalapplications/royalvnc
- **Ghostty** — manaflow-ai/ghostty fork (Zig terminal emulator)
- **Bonsplit** — manaflow-ai/bonsplit (tab/split pane library)
- **exo** — github.com/exo-explore/exo (future: distributed AI compute cluster)

---

## Product Vision Summary

**arya-cmux = cmux + VNC + AVM + Mobile Client**

A Mac mini-centric agent host platform. Users:
1. **Build** agents in isolated workspaces (VMs via Apple Virtualization)
2. **Run** them securely with AVM resource/network/PII controls
3. **Serve** them via cmux terminal + VNC remote desktop
4. **View** from anywhere — iPhone/iPad mobile client with touch controls
5. **Scale** by clustering Mac minis via exo (distributed compute)

Target market: homelab enthusiasts, indie AI builders, small agencies, privacy-conscious professionals.
Pricing: Free tier (1 host) → Pro $8-15/mo → Team $20-30/user/mo.
