# Phase 3E: Mobile Architecture Design Document

> **Status**: Design only — no code implementation
> **Platform**: iOS 17+ / iPadOS 17+ (iPhone, iPad)
> **Date**: 2026-04-06

---

## 1. Product Overview

### What It Is
An iOS/iPadOS companion app for arya-cmux that lets users:
- View and control VNC remote desktop sessions with touch gestures
- Monitor agent activity in real time (timeline + media viewer, Manus-style)
- Approve/deny AVM security prompts from anywhere
- Monitor resource usage across all Mac mini hosts

### What It Is Not
- Not a standalone terminal emulator (no local shell)
- Not a full VNC client (connection goes through the cmux host)
- Not a replacement for the macOS app (it's a remote viewer/controller)

### Target Audience
- Homelab users monitoring Mac mini agent hosts from iPhone/iPad
- Developers approving agent actions while away from desk
- Teams managing distributed Mac mini clusters

---

## 2. Communication Architecture

### 2.1 Transport Layer

All mobile-to-host communication goes through the cmux socket API (v2 JSON-RPC) tunneled over a secure transport.

```
┌──────────────┐                              ┌───────────────┐
│  iOS Client  │◄──── Tailscale / SSH ────────►│  Mac mini     │
│              │      tunnel (encrypted)       │  cmux host    │
│  cmux-mobile │                               │               │
│              │◄──── JSON-RPC v2 ────────────►│  TerminalCtrl │
│              │      over Unix socket relay   │  (socket API) │
│              │                               │               │
│              │◄──── WebRTC ─────────────────►│  VNC renderer │
│              │      (framebuffer stream)     │  (pixel data) │
└──────────────┘                               └───────────────┘
```

**Primary: Tailscale (Recommended)**
- Zero-config mesh VPN — Mac mini and iPhone both join the same tailnet
- MagicDNS: `mac-mini.tailnet-name.ts.net`
- Encrypted WireGuard tunnel, no port forwarding needed
- iOS app uses `NetworkFramework` NWConnection to connect to the cmux socket on the Tailscale IP

**Fallback: SSH Tunnel**
- For users without Tailscale: SSH port forward from iOS to Mac mini
- `ssh -L 9999:~/.cmux/socket user@host` via a library like NMSSH or libssh2
- The iOS app connects to `localhost:9999` which forwards to the Unix socket

**Socket Relay**
The cmux socket is a Unix domain socket (`~/.cmux/socket`). iOS can't connect directly over the network, so two options:

1. **TCP relay in cmux** (preferred): Add a `--tcp-listen <port>` flag to cmux that exposes the socket API on a TCP port (bound to `127.0.0.1` or Tailscale interface only). The iOS client connects via TCP over Tailscale.
2. **socat bridge** (interim): `socat TCP-LISTEN:9234,bind=100.x.y.z,fork UNIX-CONNECT:$HOME/.cmux/socket`

### 2.2 JSON-RPC v2 Protocol (Existing)

The existing socket API v2 already provides everything needed for mobile control:

```json
// Request
{"method": "workspace.list", "params": {}, "id": 1}

// Response
{"ok": true, "result": [...], "id": 1}
```

**Existing methods the mobile app will use:**
- `system.ping` — connectivity check
- `system.tree` — full app state tree
- `workspace.list` / `workspace.select` — workspace navigation
- `surface.list` / `surface.current` — panel enumeration
- `vnc.connect` / `vnc.disconnect` / `vnc.status` — VNC session control
- `vnc.screenshot` — framebuffer capture (for thumbnails/timeline)
- `notification.list` — pending notifications

**New methods needed for mobile:**
- `vnc.stream.start { surface_id, quality, fps }` — begin WebRTC stream
- `vnc.stream.stop { surface_id }` — end WebRTC stream
- `vnc.input.mouse { surface_id, x, y, buttons, scroll }` — remote mouse event
- `vnc.input.key { surface_id, keysym, down }` — remote keyboard event
- `avm.approvals.pending` — list pending approval prompts
- `avm.approvals.respond { approval_id, action: "approve"|"deny" }` — respond
- `avm.status` — global AVM status (agents, resources, events)
- `host.info` — hostname, OS version, CPU/RAM usage, uptime

### 2.3 VNC Framebuffer Streaming

For interactive VNC, polling `vnc.screenshot` is too slow. Two approaches:

**Option A: WebRTC (Recommended for low latency)**
- cmux host encodes VNC framebuffer as H.264/VP8 video stream
- WebRTC peer connection established via signaling over the JSON-RPC socket
- iOS uses `RTCMTLVideoView` or `RTCEAGLVideoView` for rendering
- Latency target: <100ms for interactive use
- Library: Google's WebRTC iOS SDK (`GoogleWebRTC` pod)

**Signaling flow:**
```
1. Mobile → cmux:  vnc.stream.start { surface_id, quality: "adaptive" }
2. cmux → Mobile:  { sdp_offer: "..." }
3. Mobile → cmux:  { sdp_answer: "..." }
4. cmux → Mobile:  { ice_candidates: [...] }
5. [WebRTC P2P data channel established over Tailscale]
6. cmux streams H.264 frames from VNC framebuffer
7. Mobile renders via hardware decoder
```

**Option B: MJPEG Fallback (Simpler, higher latency)**
- cmux host captures VNC framebuffer as JPEG at configurable FPS (5-30)
- Streams over HTTP chunked transfer or WebSocket
- iOS renders each frame as UIImage
- Latency: 100-500ms depending on quality/FPS
- Good enough for monitoring, not ideal for interactive use

**Recommended approach**: Start with Option B (MJPEG) for v1 — simpler to implement, no WebRTC dependency. Add WebRTC in v2 when interactive performance matters.

### 2.4 Input Relay

Mouse and keyboard events from the iOS touch layer are serialized and sent via JSON-RPC:

```json
// Mouse move + click
{"method": "vnc.input.mouse", "params": {
  "surface_id": "uuid",
  "x": 0.45,        // normalized 0.0-1.0 (resolution-independent)
  "y": 0.32,
  "buttons": 1,     // bitmask: 1=left, 2=middle, 4=right
  "scroll_x": 0,
  "scroll_y": -3
}, "id": 42}

// Key event
{"method": "vnc.input.key", "params": {
  "surface_id": "uuid",
  "keysym": 65307,   // X11 keysym for Escape
  "down": true
}, "id": 43}
```

The cmux host translates these into RoyalVNCKit API calls on the active VNC connection.

---

## 3. Mobile VNC Touch Mapping

### 3.1 Gesture-to-Mouse Translation

| iOS Gesture | VNC Action | Notes |
|---|---|---|
| Single tap | Left click | At tap location |
| Long press (0.5s) | Right click | Haptic feedback on trigger |
| Two-finger tap | Middle click | At midpoint of two fingers |
| Single finger drag | Mouse move + left button held | For drag operations |
| Two-finger scroll | Mouse scroll wheel | Vertical and horizontal |
| Pinch to zoom | Framebuffer zoom (local only) | Does not send to server |
| Double tap | Double left click | At tap location |
| Three-finger tap | Toggle trackpad mode | Visual indicator on screen |

### 3.2 Trackpad Mode

When trackpad mode is active (toggled via three-finger tap or toolbar button):
- **Single finger drag** = relative mouse movement (like a laptop trackpad)
- **Tap** = left click at current cursor position (not at finger position)
- **Two-finger tap** = right click at current cursor position

This is essential for precise operations where the user needs sub-pixel accuracy (e.g., resizing windows, selecting text).

### 3.3 Special Keys Panel

Activated via edge swipe from the right side of the screen:

```
┌──────────────────────────────────────┐
│  [Esc] [Tab] [Ctrl] [Alt] [Cmd]     │
│  [F1] [F2] [F3] ... [F12]           │
│  [←] [↑] [↓] [→] [Home] [End]      │
│  [PgUp] [PgDn] [Del] [Ins]          │
│  [Ctrl+Alt+Del] [Ctrl+C] [Ctrl+Z]   │
└──────────────────────────────────────┘
```

- Modifier keys (Ctrl, Alt, Cmd, Shift) are **sticky toggles** — tap to activate, tap again to deactivate
- Active modifiers shown as highlighted badges at the top of the VNC view
- Combo buttons (Ctrl+Alt+Del, Ctrl+C) send the full key sequence immediately
- Panel auto-dismisses after 5s of inactivity, or manual swipe to dismiss

### 3.4 On-Screen Keyboard

- Standard iOS keyboard for text input
- Each key press/release sent as individual `vnc.input.key` events
- Hardware keyboard (iPad Magic Keyboard, Bluetooth) events forwarded directly
- `UIKeyCommand` captures modifier+key combos from hardware keyboards

### 3.5 iPad-Specific Enhancements

- **Stage Manager**: VNC view as resizable window alongside other apps
- **Apple Pencil**: Maps to mouse movement with pressure → no special mapping needed
- **Trackpad/Mouse support**: Direct passthrough — native cursor control via `UIPointerInteraction`
- **External display**: Mirror VNC session to connected monitor (via DisplayLink or AirPlay)

---

## 4. Mobile Agent Dashboard

### 4.1 Host List (Home Screen)

```
┌─────────────────────────────────────┐
│  arya-cmux                    [⚙️]  │
│─────────────────────────────────────│
│  ┌─────────────────────────────┐    │
│  │ 🟢 mac-mini-1              │    │
│  │    3 workspaces · 2 agents  │    │
│  │    CPU 23% · RAM 6.2 GB     │    │
│  └─────────────────────────────┘    │
│  ┌─────────────────────────────┐    │
│  │ 🟡 mac-mini-2              │    │
│  │    1 workspace · 5 agents   │    │
│  │    CPU 89% · RAM 14.1 GB    │    │
│  └─────────────────────────────┘    │
│  ┌─────────────────────────────┐    │
│  │ 🔴 mac-mini-3 (offline)    │    │
│  │    Last seen: 5 min ago     │    │
│  └─────────────────────────────┘    │
│                                     │
│  [+ Add Host]                       │
└─────────────────────────────────────┘
```

- Hosts discovered via Tailscale status or manual entry (IP/hostname)
- Status colors: green (healthy), yellow (warnings/high load), red (offline/blocked)
- Tap a host to enter workspace view
- Background polling: `system.ping` + `host.info` every 30s per host

### 4.2 Workspace View (Per Host)

```
┌─────────────────────────────────────┐
│  ← mac-mini-1            [AVM ⚡]  │
│─────────────────────────────────────│
│  Workspaces                         │
│  ┌─────────────────────────────┐    │
│  │ 📁 frontend-dev             │    │
│  │    Terminal · Browser        │    │
│  │    ~/Projects/web-app        │    │
│  └─────────────────────────────┘    │
│  ┌─────────────────────────────┐    │
│  │ 🖥️ vnc-session              │    │
│  │    VNC (1920x1080) · 12m    │    │
│  │    localhost:5900            │    │
│  └─────────────────────────────┘    │
│  ┌─────────────────────────────┐    │
│  │ 🤖 claude-agent             │    │
│  │    Terminal · [AVM: safe]    │    │
│  │    Running task: refactor    │    │
│  └─────────────────────────────┘    │
│                                     │
│  Active Agents (2)                  │
│  ├─ claude-code (PID 4521)         │
│  │  CPU 12% · RAM 340 MB           │
│  └─ codex (PID 4589)              │
│     CPU 3% · RAM 180 MB            │
└─────────────────────────────────────┘
```

- Data sourced from `workspace.list` + `surface.list` + `avm.status`
- Tap workspace to view its panels
- VNC workspaces show a live thumbnail (captured via `vnc.screenshot` at 1 FPS)
- AVM badge in nav bar shows overall security status

### 4.3 Agent Activity Timeline

```
┌─────────────────────────────────────┐
│  ← claude-agent         [Live 🔴]  │
│─────────────────────────────────────│
│  ┌─────────────────────────────────┐│
│  │          [VNC Screenshot]       ││
│  │       (live or last capture)    ││
│  │                                 ││
│  └─────────────────────────────────┘│
│                                     │
│  ──────●────────────────── 2:34 PM  │
│  [◀] [▶]            [Jump to Live] │
│                                     │
│  Timeline                           │
│  2:34 PM  📝 Editing main.swift    │
│  2:31 PM  🔍 Reading Package.swift │
│  2:28 PM  ⚠️ AVM: blocked curl    │
│  2:25 PM  ✅ Tests passing (12/12) │
│  2:20 PM  🚀 Agent started        │
│                                     │
│  [Approve Pending (1)]             │
└─────────────────────────────────────┘
```

- Timeline events from workspace log entries (`logEntries` in SessionWorkspaceSnapshot)
- VNC screenshot updates every 5s when viewing, paused when scrolling timeline
- Scrubber bar: drag to see historical screenshots (if captured)
- "Jump to Live" button snaps to current state
- Pending AVM approvals shown as actionable banners

### 4.4 AVM Approval Flow

When an agent triggers a security prompt:

```
┌─────────────────────────────────────┐
│         ⚠️ Agent Request            │
│─────────────────────────────────────│
│                                     │
│  claude-code wants to run:          │
│                                     │
│  ┌─────────────────────────────┐    │
│  │ curl https://api.example.com│    │
│  │   /v1/deploy --data @pkg.gz │    │
│  └─────────────────────────────┘    │
│                                     │
│  Domain: api.example.com            │
│  Category: HTTP egress              │
│  Risk: Medium                       │
│                                     │
│  Auto-deny in: 27s                  │
│                                     │
│  [Deny]              [Approve]      │
└─────────────────────────────────────┘
```

- Push notification triggers this view (even from lock screen via notification action)
- 30s countdown to auto-deny (matches AVM policy default)
- Approve/deny calls `avm.approvals.respond` via socket API
- History of past approvals viewable in AVM dashboard

### 4.5 Push Notifications

Delivered via Apple Push Notification Service (APNs):

| Event | Priority | Sound |
|---|---|---|
| Agent completed task | Normal | Default |
| AVM approval needed | Time-sensitive | Alert |
| Agent blocked/killed | High | Alert |
| Host went offline | Normal | None |
| Resource warning (>80% CPU/RAM) | Normal | None |

**Implementation**: cmux host sends push via a lightweight relay:
1. Mobile app registers device token with cmux host (stored locally)
2. cmux host runs a small push relay (or uses ntfy.sh/Pushover as interim)
3. On event, cmux calls the relay which forwards to APNs

---

## 5. Shared Swift Code Architecture

### 5.1 Package Structure

```
cmux-shared/                          # Swift Package (shared between macOS + iOS)
├── Package.swift
├── Sources/
│   ├── CMUXProtocol/                 # JSON-RPC v2 protocol layer
│   │   ├── SocketMessage.swift       # Request/Response envelope types
│   │   ├── MethodRouter.swift        # Method name → handler dispatch
│   │   └── ParameterExtractors.swift # v2String(), v2UUID(), v2Bool(), etc.
│   │
│   ├── CMUXModels/                   # Shared data models
│   │   ├── PanelType.swift           # .terminal, .browser, .vnc, .markdown
│   │   ├── WorkspaceInfo.swift       # Lightweight workspace descriptor
│   │   ├── PanelInfo.swift           # Lightweight panel descriptor
│   │   ├── VNCConnectionInfo.swift   # Host, port, status, duration
│   │   └── AVMModels.swift           # AVMAgentInfo, AVMSecurityStatus, etc.
│   │
│   ├── CMUXPersistence/              # Session snapshot models (Codable)
│   │   ├── SessionSnapshot.swift     # AppSessionSnapshot hierarchy
│   │   └── PersistencePolicy.swift   # Truncation, limits, defaults
│   │
│   └── CMUXClient/                   # Client SDK for connecting to cmux
│       ├── CMUXConnection.swift      # TCP/UDS transport abstraction
│       ├── CMUXClient.swift          # High-level API: listWorkspaces(), vncConnect(), etc.
│       └── AVMClient.swift           # AVM-specific operations
│
├── Tests/
│   └── CMUXProtocolTests/
│       ├── MessageParsingTests.swift
│       └── ParameterExtractorTests.swift
```

### 5.2 What's Shared vs Platform-Specific

| Component | Shared | macOS-Specific | iOS-Specific |
|---|---|---|---|
| JSON-RPC protocol | Message types, routing, parameter extraction | Unix socket I/O | TCP over NetworkFramework |
| Data models | PanelType, WorkspaceInfo, AVMModels | — | — |
| Session snapshots | All Codable structs | Window frame, sidebar | — |
| AVM client | Request/response types, status computation | Unix socket transport | TCP transport |
| VNC rendering | Connection info, scaling mode enum | RoyalVNCKit + NSView | WebRTC + UIView |
| Panel protocol | PanelType, display metadata | Ghostty/WebKit/AppKit | SwiftUI views |
| Keychain | — | Security.framework | Keychain Services (iOS) |
| Push notifications | — | — | UserNotifications + APNs |
| Touch input | — | — | Gesture recognizers, UIKit |

### 5.3 Extraction Plan

Extracting shared code from the current macOS codebase:

**Phase 1 — Extract protocol types (no behavior change)**
1. Move `V2CallResult`, request/response envelope structs into `CMUXProtocol`
2. Move `PanelType`, `AVMAgentInfo`, `AVMSecurityStatus`, `AVMProxyInfo` into `CMUXModels`
3. Move `SessionPanelSnapshot`, `SessionWorkspaceSnapshot`, etc. into `CMUXPersistence`
4. macOS app imports `cmux-shared` package, no functional changes

**Phase 2 — Build client SDK**
1. Abstract socket transport behind `CMUXTransport` protocol (UDS vs TCP)
2. Build `CMUXClient` with typed methods for each API endpoint
3. Use in iOS app; optionally use in macOS CLI too

**Phase 3 — iOS app scaffold**
1. New Xcode project: `cmux-mobile` (iOS 17+, SwiftUI)
2. Depends on `cmux-shared` package
3. Implement platform-specific transport, views, and input handling

---

## 6. iOS App Structure

### 6.1 Target Configuration

```
cmux-mobile/
├── cmux-mobile.xcodeproj
├── cmux-mobile/
│   ├── App.swift                     # @main, scene configuration
│   ├── Models/
│   │   ├── HostConnection.swift      # Saved host configs (Tailscale IP, name)
│   │   └── AppState.swift            # Global observable state
│   ├── Networking/
│   │   ├── TCPTransport.swift        # NWConnection-based CMUXTransport
│   │   ├── WebRTCManager.swift       # WebRTC session management
│   │   └── PushManager.swift         # APNs registration + handling
│   ├── Views/
│   │   ├── HostListView.swift        # Home screen: list of Mac mini hosts
│   │   ├── WorkspaceListView.swift   # Per-host workspace browser
│   │   ├── VNCView.swift             # VNC remote desktop with touch
│   │   ├── AgentTimelineView.swift   # Activity timeline + scrubber
│   │   ├── AVMApprovalView.swift     # Security approval prompt
│   │   ├── AVMDashboardView.swift    # Resource monitor (avm top)
│   │   └── SpecialKeysPanel.swift    # Floating key panel for VNC
│   ├── Input/
│   │   ├── TouchToMouseTranslator.swift
│   │   ├── TrackpadMode.swift
│   │   └── KeyboardInputManager.swift
│   └── Extensions/
│       └── HapticFeedback.swift
├── cmux-mobileTests/
└── cmux-mobileUITests/
```

### 6.2 Key SwiftUI Views

**VNCView** — the core remote desktop experience:
```swift
// Conceptual structure (not implementation code)
struct VNCView: View {
    @StateObject var session: VNCSession  // WebRTC or MJPEG stream
    @State var isTrackpadMode = false
    @State var showSpecialKeys = false
    @State var zoomScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Framebuffer layer (WebRTC video or MJPEG images)
            FramebufferView(session: session)
                .gesture(tapGesture)
                .gesture(longPressGesture)
                .gesture(panGesture)
                .gesture(pinchGesture)
                .gesture(scrollGesture)

            // Overlay: active modifiers, connection status
            VStack {
                ModifierBadgeBar(activeModifiers: session.activeModifiers)
                Spacer()
                ConnectionStatusBar(session: session)
            }

            // Special keys panel (edge swipe)
            if showSpecialKeys {
                SpecialKeysPanel(onKey: session.sendKey)
            }
        }
    }
}
```

### 6.3 State Management

```swift
@MainActor
class AppState: ObservableObject {
    @Published var hosts: [HostConnection] = []
    @Published var activeHost: HostConnection?
    @Published var pendingApprovals: [AVMApproval] = []

    // Per-host state (lazy, created on connect)
    var hostClients: [UUID: CMUXClient] = [:]

    func connect(to host: HostConnection) async throws {
        let transport = TCPTransport(host: host.address, port: host.port)
        let client = CMUXClient(transport: transport)
        try await client.connect()
        hostClients[host.id] = client
        activeHost = host
    }
}
```

---

## 7. WebRTC Implementation Plan

### 7.1 macOS Host Side (cmux)

Add a WebRTC server component to cmux that:
1. Captures VNC framebuffer pixels (already available via `VNCFramebuffer`)
2. Encodes as H.264 using VideoToolbox (hardware-accelerated on Apple Silicon)
3. Wraps in WebRTC peer connection using `WebRTC.framework`
4. Sends video track to connected mobile clients

```
VNCFramebuffer → CVPixelBuffer → VTCompressionSession → WebRTC VideoTrack → Mobile
```

### 7.2 iOS Client Side

1. Receive WebRTC video track
2. Render via `RTCMTLVideoView` (Metal-backed, hardware-decoded)
3. Send mouse/keyboard events back via WebRTC data channel (lower latency than JSON-RPC for input)

### 7.3 Signaling

WebRTC signaling (SDP offer/answer, ICE candidates) flows over the existing JSON-RPC socket:
- No separate signaling server needed
- cmux socket already supports bidirectional JSON messaging
- ICE candidates include Tailscale IP for direct P2P (no TURN server needed on same tailnet)

### 7.4 Quality Adaptation

```json
{
  "quality_profiles": {
    "interactive": { "fps": 30, "bitrate_kbps": 3000, "resolution": "native" },
    "monitoring":   { "fps": 10, "bitrate_kbps": 1000, "resolution": "720p" },
    "thumbnail":    { "fps": 1,  "bitrate_kbps": 200,  "resolution": "360p" }
  }
}
```

- Auto-switch based on network conditions (WebRTC bandwidth estimation)
- User can pin a quality mode from the VNC toolbar
- Thumbnail mode used for dashboard previews (low bandwidth)

---

## 8. Security Considerations

### 8.1 Authentication

- **Host pairing**: First connection requires a one-time code displayed on the Mac mini
- **Persistent auth**: After pairing, use Ed25519 key pair stored in iOS Keychain
- **Session tokens**: JWT with 24h expiry, refreshed automatically
- **Biometric gate**: Face ID / Touch ID required to approve AVM actions

### 8.2 Encryption

- **Transport**: All traffic over Tailscale WireGuard tunnel (encrypted by default)
- **Socket API**: Additional TLS layer if TCP relay used outside Tailscale
- **Credentials**: Never stored on mobile — VNC passwords stay on the Mac mini host
- **Screenshots**: Cached locally with NSFileProtectionComplete (encrypted at rest, unavailable when locked)

### 8.3 Privacy

- No telemetry or analytics sent to external servers
- No cloud relay — all communication is direct (host ↔ mobile)
- Session data purged on app uninstall
- AVM approval history stored on host only (mobile gets ephemeral view)

---

## 9. Implementation Phases

### Phase M1: Foundation (2-3 weeks)
- [ ] Create `cmux-shared` Swift package, extract protocol + model types
- [ ] Add TCP relay option to cmux (`--tcp-listen`)
- [ ] Scaffold iOS app with host list + basic connection
- [ ] Implement `CMUXClient` with workspace.list, system.ping
- [ ] Host discovery via manual entry (Tailscale IP)

### Phase M2: Dashboard (2-3 weeks)
- [ ] Workspace list view with panel details
- [ ] Agent activity timeline (read-only)
- [ ] AVM status display
- [ ] AVM approval push notifications + action handling
- [ ] MJPEG VNC thumbnail in workspace cards

### Phase M3: VNC Viewer (3-4 weeks)
- [ ] MJPEG framebuffer streaming (v1 — simpler)
- [ ] Touch-to-mouse gesture translation
- [ ] Special keys panel
- [ ] Trackpad mode
- [ ] On-screen keyboard integration
- [ ] iPad trackpad/mouse passthrough

### Phase M4: WebRTC Upgrade (3-4 weeks)
- [ ] VideoToolbox H.264 encoding on macOS host
- [ ] WebRTC signaling over JSON-RPC socket
- [ ] `RTCMTLVideoView` rendering on iOS
- [ ] Input events over WebRTC data channel
- [ ] Adaptive quality profiles

### Phase M5: Polish (2 weeks)
- [ ] Host pairing flow (one-time code)
- [ ] Face ID for AVM approvals
- [ ] Widget: AVM status, active agents count
- [ ] Spotlight integration: search workspaces/hosts
- [ ] iPad Stage Manager optimization

---

## 10. Dependencies

| Dependency | Purpose | License |
|---|---|---|
| `cmux-shared` | Protocol, models, client SDK | Internal |
| `GoogleWebRTC` | WebRTC for VNC streaming (Phase M4) | BSD-3 |
| NetworkFramework | TCP transport (system framework) | Apple |
| UserNotifications | Push notifications | Apple |
| Security | Keychain for host credentials | Apple |
| LocalAuthentication | Face ID / Touch ID | Apple |

---

## 11. Open Questions

1. **Tailscale SDK vs manual config?** — Tailscale has an iOS SDK for embedding VPN directly in the app. Worth evaluating vs requiring the standalone Tailscale app.
2. **WebRTC library choice** — GoogleWebRTC is large (~40MB). Consider LiveKit (built on WebRTC, lighter SDK) or Amazon Chime SDK as alternatives.
3. **Multi-host management** — Should the mobile app support connecting to multiple hosts simultaneously, or one at a time? (Recommendation: one active, multiple saved)
4. **App Store distribution** — VNC + shell control apps may trigger additional review. Plan for clear "this is a remote management tool" messaging.
5. **Notification relay** — Build custom APNs integration vs use ntfy.sh/Pushover as interim? (Recommendation: ntfy.sh for v1, custom for v2)
