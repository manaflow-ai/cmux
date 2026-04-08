# Technical Specification: Phase 3 — arya-cmux Agent Host Platform

## Difficulty: Hard

Multiple subsystems (VNC UX, SSH, CLI, socket API, AVM daemon), new daemon architecture, Keychain integration, and deep integration with existing socket/CLI infrastructure.

---

## Technical Context

- **Language**: Swift 5.9+ (macOS app), Go (remote daemon), Zig (ghostty/cmuxd), Rust (proposed AVM daemon)
- **Platforms**: macOS 13+, Apple Silicon
- **Key Dependencies**: RoyalVNCKit v1.1.0 (MIT), Ghostty (Zig), Bonsplit (Swift)
- **Build System**: Xcode project + SPM (Package.swift), Zig build for subcomponents
- **Socket Protocol**: v1 (space-delimited text) + v2 (JSON-RPC) over Unix domain sockets
- **CLI**: Swift CLI (`CLI/cmux.swift`) communicating via socket to running app

---

## Current State (Phase 1 Complete)

### What exists:
- `VNCPanel.swift` (243 lines): Connection lifecycle, ARD/VNC/UltraVNC auth, VNCConnectionDelegate
- `VNCPanelView.swift` (240 lines): Connection form (host/port/user/pass), NSViewRepresentable for framebuffer
- Panel type registered in `Panel.swift`, `PanelContentView.swift`, `Workspace.swift`, `TabManager.swift`
- Command palette entry in `ContentView.swift` ("New Tab (VNC Remote Desktop)")
- RoyalVNCKit SPM dependency in `Package.swift`
- Connection works, framebuffer renders, auth (VNC/ARD/UltraVNC) works

### Known issues:
- Port shows "5,900" due to locale formatting (already fixed via `String(port)` binding)
- No disconnect/reconnect buttons when connected
- No connection timeout handling
- No Keychain credential storage
- No CLI or socket API for VNC
- No session persistence across restarts

---

## Implementation Approach

### Phase 3A: VNC Panel Polish (Priority: HIGH)

#### 3A.1 Connection UX Polish
**Files modified**: `Sources/Panels/VNCPanelView.swift`, `Sources/Panels/VNCPanel.swift`

- Add connection timeout (30s) using `DispatchQueue.main.asyncAfter` with cancellation token
- Add "Disconnect" button visible when `isConnected == true`
- Add "Reconnect" button visible when disconnected after a previous connection
- Show connection duration in `displayTitle` via a Timer that updates every second
- Show detailed error messages: map `VNCError` subtypes to user-friendly strings
- Verify port binding already uses `String(port)` (not locale-formatted)

**Pattern**: Follow existing `connectionView` structure in `VNCPanelView.swift`. The connection form is already well-structured; add states for connected/disconnected-with-history.

#### 3A.2 Mouse & Keyboard Input
**Files**: `Sources/Panels/VNCPanelView.swift` (verify), `Sources/Panels/VNCPanel.swift`

`VNCCAFramebufferView` from RoyalVNCKit natively handles:
- Mouse tracking, clicks, scroll
- Keyboard input (key down/up)
- Modifier keys

**Work required**:
- Verify these work by testing (mostly verification, not code changes)
- Add a toolbar with "Send Ctrl+Alt+Del" button for Windows VMs
- Ensure `VNCCAFramebufferView` becomes first responder when the VNC panel is focused

**Pattern**: Focus management follows existing `VNCPanel.focus()` which calls `window.makeFirstResponder(view)`.

#### 3A.3 Display Quality
**Files**: `Sources/Panels/VNCPanel.swift`, `Sources/Panels/VNCPanelView.swift`

- Add `scalingMode` enum: `.fitToWindow` (default), `.oneToOne`, `.customZoom(CGFloat)`
- Add `colorDepth` setting to `VNCConnection.Settings` (already set to `.depth24Bit`)
- Handle `didResizeFramebuffer` delegate callback (already implemented)
- For retina: check `VNCCAFramebufferView` layer backing and `contentsScale`

#### 3A.4 Clipboard
**Files**: None expected — verify only

- RoyalVNCKit has `isClipboardRedirectionEnabled: true` already set in `VNCPanel.connect()`
- Verification task: test copy/paste in both directions

#### 3A.5 Session Management (Keychain)
**Files**: New `Sources/Panels/VNCKeychainStore.swift`, modified `VNCPanel.swift`, `VNCPanelView.swift`

- Create `VNCKeychainStore` using Security framework (follow pattern from `SocketControlSettings.swift`)
- Store: hostname, port, username per entry; password in Keychain
- `kSecClass: kSecClassGenericPassword`, service: `com.arya-cmux.vnc`, account: `host:port`
- Add recent connections dropdown in connection form
- Session persistence: extend `SessionPersistence` to include VNC panels (hostname/port/username, reconnect on restore)

**Keychain pattern** (from existing codebase):
```swift
let query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "com.arya-cmux.vnc",
    kSecAttrAccount: "\(hostname):\(port)",
    kSecReturnData: true,
    kSecMatchLimit: kSecMatchLimitOne,
]
```

---

### Phase 3B: SSH Session Reliability (Priority: HIGH)

#### 3B.1 SSH Input Fixes
**Files**: `Sources/TerminalSSHSessionDetector.swift` (807 lines — audit only)

- Audit SSH session detection logic for input handling edge cases
- This is primarily investigation + testing work, not feature development
- Check TERM variable, UTF-8 encoding, echo/cursor behavior
- The SSH session runs inside Ghostty terminal — issues likely in terminal emulation, not cmux

#### 3B.2 SSH Reconnection
**Files**: `Sources/TerminalSSHSessionDetector.swift`, `Sources/Panels/TerminalPanel.swift`

- Detect SSH disconnect (monitor process exit or PTY EOF)
- Show "Reconnecting..." in tab title
- Implement auto-reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s)
- Preserve scrollback by keeping the terminal surface alive, only reconnecting the SSH process

#### 3B.3 SSH + VNC Integration
**Files**: `Sources/Panels/VNCPanel.swift`, `Sources/TerminalSSHSessionDetector.swift`

- `cmux ssh user@host --vnc`: detect VNC port on remote, SSH tunnel it, open VNC panel
- Reuse `BrowserProxyEndpoint` pattern from `BrowserPanel.swift` for SOCKS proxy
- This is a stretch goal — depends on SSH tunnel infrastructure

---

### Phase 3C: CLI Commands (Priority: MEDIUM)

#### 3C.1 VNC CLI Commands
**Files**: `CLI/cmux.swift`, `Sources/TerminalController.swift`

**CLI side** (in `CLI/cmux.swift`):
- Add `vnc` subcommand group: `cmux vnc <host>:<port>`, `cmux vnc list`, `cmux vnc disconnect <id>`
- Follow existing CLI command pattern (argument parsing -> socket message -> response)

**App side** (in `TerminalController.swift`):
- Add v1 socket commands: `vnc_connect`, `vnc_disconnect`, `vnc_list`, `vnc_status`
- Add v2 JSON-RPC handlers: `vnc.connect`, `vnc.disconnect`, `vnc.status`, `vnc.screenshot`
- Follow existing command dispatch pattern in `handleClient()`

**Pattern** from existing socket commands:
```swift
case "vnc_connect":
    // Parse hostname, port from args
    // Call tabManager.openVNC()
    // Return panel ID
```

#### 3C.2 VNC Screenshot
**Files**: `Sources/Panels/VNCPanel.swift`

- Capture current framebuffer as PNG: `VNCFramebuffer` -> `CGImage` -> PNG data
- Expose via socket command `vnc.screenshot { surface_id }` -> base64 PNG

---

### Phase 3D: AVM Security Runtime Foundation (Priority: MEDIUM)

#### 3D.1 avmd Daemon Architecture
**New directory**: `avm/` at project root

**Language decision**: Rust (aligns with user's stack preferences — Edition 2024, MSRV 1.85)

**Structure**:
```
avm/
  Cargo.toml
  src/
    main.rs          — daemon entry, UDS listener
    registry.rs      — agent process registry (PID, name, resources)
    policy.rs        — policy file parser (~/.hyperspace/avm-policy.json)
    governor.rs      — resource governor (setrlimit, task_info sampling)
    proxy.rs         — HTTP(S) proxy for egress control
    detector.rs      — PII/credential detection
    shell.rs         — command approval wrapper
```

**Dependencies**: tokio, serde, serde_json, anyhow, thiserror, regex

**Socket**: Unix domain socket at `~/.hyperspace/avm.sock`

**Policy file**: `~/.hyperspace/avm-policy.json`
```json
{
  "resource_caps": {
    "cpu_time_seconds": 300,
    "rss_mb": 512,
    "address_space_mb": 2048
  },
  "network": {
    "allowed_domains": ["api.openai.com", "api.anthropic.com"],
    "blocked_domains": ["*.onion"],
    "default": "allow"
  },
  "pii_detection": {
    "patterns": ["email", "credit_card", "aws_key", "bearer_token"],
    "action": "warn"
  },
  "command_approval": {
    "dangerous_patterns": ["rm -rf /", "curl | sh", "chmod 777"],
    "action": "ask",
    "timeout_seconds": 30
  }
}
```

#### 3D.2-3D.3 Egress Control & Command Approval
Part of `avmd` daemon — HTTP proxy with domain filtering, PII regex matching, command wrapper.

#### 3D.4 CMUX Integration
**Files**: `Sources/cmuxApp.swift`, `Sources/Workspace.swift`, `Sources/ContentView.swift`

- Add AVM status indicators on tabs (green/yellow/red badges)
- `avm top` CLI command showing agent processes, CPU/RAM, security events
- Agent panes launched through avmd instead of raw shell

---

### Phase 3E: Mobile Architecture (Priority: LOW — Design Only)

No code implementation. Design document only covering:
- Touch-to-mouse mapping
- cmux socket API over Tailscale/SSH tunnel
- WebRTC for VNC streaming
- Shared Swift code architecture

---

## Source Code Structure Changes

### New Files
| File | Purpose |
|------|---------|
| `Sources/Panels/VNCKeychainStore.swift` | Keychain CRUD for VNC credentials |
| `avm/Cargo.toml` | AVM daemon Rust project |
| `avm/src/main.rs` | AVM daemon entry point |
| `avm/src/registry.rs` | Agent process registry |
| `avm/src/policy.rs` | Policy file parser |
| `avm/src/governor.rs` | Resource governor |
| `avm/src/proxy.rs` | HTTP(S) egress proxy |
| `avm/src/detector.rs` | PII/credential detection |
| `avm/src/shell.rs` | Command approval wrapper |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/Panels/VNCPanel.swift` | Timeout, disconnect/reconnect, duration timer, scaling modes |
| `Sources/Panels/VNCPanelView.swift` | Disconnect/reconnect buttons, toolbar, recent connections, scaling UI |
| `Sources/TerminalController.swift` | Add VNC socket commands (v1 + v2) |
| `CLI/cmux.swift` | Add `vnc` CLI subcommand group |
| `Sources/TerminalSSHSessionDetector.swift` | SSH reconnection, VNC tunnel detection |
| `Sources/cmuxApp.swift` | AVM status menu items |
| `Sources/Workspace.swift` | VNC session persistence |
| `Sources/ContentView.swift` | AVM status indicators |

---

## Data Model Changes

### VNC Credential Storage (Keychain)
- Service: `com.arya-cmux.vnc`
- Account: `hostname:port`
- Data: password (encrypted by Keychain)
- Metadata: username stored in UserDefaults (`vnc.recentConnections` array)

### VNC Session Persistence
- Extend existing session persistence to include VNC panels
- Store: `{ panelType: "vnc", hostname, port, username }`
- On restore: create VNCPanel with saved params, auto-connect if credentials in Keychain

### AVM Policy Schema
- JSON file at `~/.hyperspace/avm-policy.json`
- Versioned schema with resource caps, network policy, PII patterns, command approval rules

---

## Verification Approach

### Build Verification
```bash
# Swift app (per CLAUDE.md — always use reload.sh with tag)
./scripts/reload.sh --tag phase3-vnc

# AVM daemon (Rust)
cd avm && cargo clippy --all-targets && cargo test
```

### Manual Testing
1. VNC Connection UX: Connect/disconnect/reconnect cycle, verify timeout, error messages
2. VNC Input: Mouse tracking, clicks, keyboard, modifier keys, Ctrl+Alt+Del button
3. VNC Clipboard: Copy text remote->local and local->remote
4. VNC Keychain: Save credentials, restart app, verify auto-fill
5. SSH: Connect to remote host, verify input/output, test reconnect on network drop
6. CLI: `cmux vnc localhost:5900`, `cmux vnc list`, `cmux vnc disconnect <id>`
7. AVM: `avmd` starts, policy loads, agent spawns tracked, resource limits enforced

### Integration Tests (CI)
- Socket tests in `tests_v2/`: add `test_vnc_api.py` for VNC socket commands
- Unit tests in `cmuxTests/`: add `VNCKeychainStoreTests.swift`
- AVM: `cargo test` in `avm/` directory

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| RoyalVNCKit input handling may not work as expected | Test early; VNCCAFramebufferView should handle natively |
| SSH reconnection may lose terminal state | Keep surface alive, only reconnect PTY |
| AVM HTTP proxy complexity | Start with logging-only proxy, add blocking later |
| Keychain permission prompts | Use app-specific Keychain access group |
| Large scope creep | Strict phase ordering — complete 3A before 3B, etc. |
