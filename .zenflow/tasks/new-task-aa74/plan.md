# Spec and build

## Configuration
- **Artifacts Path**: {@artifacts_path} → `.zenflow/tasks/{task_id}`

---

## Agent Instructions

Ask the user questions when anything is unclear or needs their input. This includes:
- Ambiguous or incomplete requirements
- Technical decisions that affect architecture or user experience
- Trade-offs that require business context

Do not make assumptions on important decisions — get clarification first.

---

## Workflow Steps

### [x] Step: Technical Specification
<!-- chat-id: 57911ae9-1033-40ed-80f2-84c5de0dd597 -->

Spec saved to `.zenflow/tasks/new-task-aa74/spec.md`. Difficulty: **Hard**.

---

### [x] Step: VNC Connection UX Polish (Phase 3A.1)
<!-- chat-id: dfadf790-ca42-4e97-aba7-0707f875be43 -->

Improve the VNC connection experience in `VNCPanel.swift` and `VNCPanelView.swift`:

- Add 30s connection timeout with cancellation token in `VNCPanel.connect()`
- Add "Disconnect" button visible when `isConnected == true`
- Add "Reconnect" button visible after disconnection (track `hasConnectedBefore` state)
- Show connection duration in `displayTitle` via a `Timer` (update every second)
- Improve error messages: map `VNCError` subtypes to user-friendly strings
- Verify port display uses `String(port)` (not locale-formatted)

**Verification**: `./scripts/reload.sh --tag phase3-vnc` — test connect/disconnect/reconnect cycle, verify timeout fires after 30s, check error messages on auth failure.

---

### [x] Step: VNC Input Verification & Toolbar (Phase 3A.2)
<!-- chat-id: 948bf3db-4fb2-46b9-8e8b-083dab79f0d1 -->

Verify and enhance keyboard/mouse input in VNC sessions:

- Verify `VNCCAFramebufferView` handles mouse tracking, clicks, scroll natively
- Verify keyboard input forwarding (key down/up, modifiers, special keys)
- Add toolbar overlay with "Send Ctrl+Alt+Del" button (for Windows VMs)
- Ensure `VNCCAFramebufferView` becomes first responder when VNC panel is focused
- Test focus management: clicking VNC panel should capture keyboard input

**Files**: `Sources/Panels/VNCPanelView.swift`, `Sources/Panels/VNCPanel.swift`

**Verification**: `./scripts/reload.sh --tag phase3-vnc` — connect to VNC, verify mouse movement/clicks, type text, test Ctrl+Alt+Del button.

---

### [x] Step: VNC Display Quality & Clipboard (Phase 3A.3-3A.4)
<!-- chat-id: 74ca9cc8-b78b-47fe-ae78-aed8f7f147e8 -->

Display scaling and clipboard verification:

- Add `VNCScalingMode` enum: `.fitToWindow`, `.oneToOne`, `.customZoom(CGFloat)`
- Add scaling mode selector in connected VNC view (toolbar or menu)
- Verify retina/HiDPI: check `VNCCAFramebufferView` layer `contentsScale`
- Verify bidirectional clipboard (already enabled: `isClipboardRedirectionEnabled: true`)
- Test copy/paste in both directions (remote->local, local->remote)

**Files**: `Sources/Panels/VNCPanel.swift`, `Sources/Panels/VNCPanelView.swift`

**Verification**: `./scripts/reload.sh --tag phase3-vnc` — test scaling modes, clipboard copy/paste.

---

### [x] Step: VNC Keychain & Session Persistence (Phase 3A.5)
<!-- chat-id: 5cbea30e-6192-41c8-baef-7fb43f782db1 -->

Credential storage and session restore:

- Create `Sources/Panels/VNCKeychainStore.swift` — Keychain CRUD using Security framework
  - Service: `com.arya-cmux.vnc`, Account: `host:port`
  - Save/load/delete password operations
  - Follow existing pattern from `SocketControlSettings.swift`
- Add recent connections list (stored in UserDefaults: hostname, port, username)
- Add recent connections dropdown in connection form
- Extend session persistence to save/restore VNC panels across app restarts
- Auto-fill credentials from Keychain on connection form load

**Files**: New `Sources/Panels/VNCKeychainStore.swift`, modified `VNCPanel.swift`, `VNCPanelView.swift`, `Sources/Workspace.swift`

**Verification**: `./scripts/reload.sh --tag phase3-vnc` — save connection, restart app, verify auto-fill and session restore.

---

### [x] Step: SSH Input Audit & Reconnection (Phase 3B.1-3B.2)
<!-- chat-id: 6cad58b4-bf44-4a40-9dfc-681ed0bfacbc -->

SSH session reliability improvements:

- Audit `Sources/TerminalSSHSessionDetector.swift` for input handling issues
- Check TERM variable, UTF-8 encoding, echo/cursor behavior in SSH sessions
- Implement auto-reconnect on SSH session drop (detect PTY EOF or process exit)
- Show "Reconnecting..." in tab title during reconnection
- Exponential backoff: 1s, 2s, 4s, 8s, max 30s
- Preserve scrollback by keeping terminal surface alive

**Files**: `Sources/TerminalSSHSessionDetector.swift`, terminal panel files

**Verification**: `./scripts/reload.sh --tag phase3-ssh` — SSH to remote host, disconnect network, verify reconnection.

---

### [x] Step: VNC CLI & Socket Commands (Phase 3C)
<!-- chat-id: e9f705fb-e898-4227-967b-10ca64504e0e -->

Add CLI and socket API for VNC control:

- **CLI** (`CLI/cmux.swift`): Add `vnc` subcommand group
  - `cmux vnc <host>:<port>` — open VNC panel
  - `cmux vnc list` — list active VNC connections
  - `cmux vnc disconnect <id>` — disconnect VNC session
  - `cmux vnc screenshot <id> --out <path>` — capture framebuffer as PNG
- **Socket v1** (`Sources/TerminalController.swift`): `vnc_connect`, `vnc_disconnect`, `vnc_list`, `vnc_status`
- **Socket v2** (JSON-RPC): `vnc.connect`, `vnc.disconnect`, `vnc.status`, `vnc.screenshot`
- **Screenshot**: Capture `VNCFramebuffer` -> `CGImage` -> PNG data -> base64

**Verification**: `./scripts/reload.sh --tag phase3-cli` — test all CLI commands, verify socket API via `tests_v2/`.

---

### [x] Step: AVM Daemon Foundation (Phase 3D.1)
<!-- chat-id: 6866f618-cc6f-4e02-b3f8-bbb004b2a7c2 -->

Create the AVM (Agent Virtual Machine) security runtime daemon in Rust:

- Create `avm/` directory with Cargo.toml (Edition 2024, MSRV 1.85)
- `src/main.rs`: UDS listener at `~/.hyperspace/avm.sock`, tokio async runtime
- `src/registry.rs`: Agent process registry (PID, name, resource tracking)
- `src/policy.rs`: Parse `~/.hyperspace/avm-policy.json` (resource caps, network policy, PII patterns)
- `src/governor.rs`: Resource governor using `setrlimit` + `task_info` sampling
- Kill switch: SIGSTOP/SIGKILL for agents exceeding limits
- Dependencies: tokio, serde, serde_json, anyhow, thiserror, regex

**Verification**: `cd avm && cargo clippy --all-targets && cargo test` — verify daemon starts, loads policy, tracks processes.

---

### [x] Step: AVM Egress Control & Command Approval (Phase 3D.2-3D.3)
<!-- chat-id: a3e7b12f-b05d-4462-853f-38d35d26f42b -->

Network and command security for AVM:

- `src/proxy.rs`: HTTP(S) proxy with domain allow/deny list
- Set `HTTP_PROXY`/`HTTPS_PROXY` env vars for agent shells
- Log all outbound requests (URL, headers, redacted body)
- `src/detector.rs`: PII/credential regex detection (emails, card numbers, AWS keys, bearer tokens)
- `src/shell.rs`: `avm-sh` wrapper detecting dangerous commands (`rm -rf /`, `curl | sh`, `chmod 777`)
- Pause + prompt user (30s timeout, auto-deny)

**Verification**: `cd avm && cargo clippy --all-targets && cargo test` — test proxy filtering, PII detection, command approval.

---

### [x] Step: AVM cmux Integration (Phase 3D.4)
<!-- chat-id: d4a56609-49a9-4705-ad01-268ce7d0086a -->

Connect AVM daemon to cmux UI:

- Agent panes launched via avmd instead of raw shell
- AVM status indicators on tabs (green/yellow/red badges)
- `avm top` CLI command: processes, CPU/RAM, security events
- AVM sidebar section in cmux

**Files**: `Sources/cmuxApp.swift`, `Sources/Workspace.swift`, `Sources/ContentView.swift`, `CLI/cmux.swift`

**Verification**: `./scripts/reload.sh --tag phase3-avm` — verify status indicators, `avm top` output.

---

### [x] Step: Mobile Architecture Design Document (Phase 3E)
<!-- chat-id: 3c303f05-603e-4265-96b9-b9555281fb1e -->

Design-only deliverable (no code):

- Touch-to-mouse mapping specification (tap, long press, pinch, scroll, edge swipe)
- Mobile agent dashboard wireframes (host list, workspace list, activity timeline)
- Communication architecture: cmux socket API over Tailscale/SSH tunnel
- WebRTC plan for low-latency VNC streaming to mobile
- Shared Swift code strategy (macOS host app + iOS client)

**Output**: Save to `.zenflow/tasks/new-task-aa74/mobile-architecture.md`
