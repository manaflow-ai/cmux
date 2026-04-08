# SPEC: VNC Remote Desktop Panel for arya-cmux

## Status: Phase 1 Complete (Connection + Auth + Framebuffer View)

## What's Built

### Phase 1 - Core VNC Panel (Done)
- [x] RoyalVNCKit (v1.1.0) integrated as SPM dependency
- [x] `VNCPanel.swift` — connection lifecycle, ARD/VNC/UltraVNC auth
- [x] `VNCPanelView.swift` — connection form (host/port/user/pass), framebuffer view
- [x] Registered in PanelType, PanelContentView, Workspace, TabManager, ContentView
- [x] Command palette: "New Tab (VNC Remote Desktop)"
- [x] Error display for auth failures
- [x] Tab title updates with resolution on connect

### Files
```
Sources/Panels/VNCPanel.swift          — Panel model, VNCConnectionDelegate
Sources/Panels/VNCPanelView.swift      — SwiftUI view, connection form, NSViewRepresentable
Sources/Panels/Panel.swift             — Added .vnc to PanelType
Sources/Panels/PanelContentView.swift  — Added .vnc dispatch
Sources/Workspace.swift                — newVNCSurface(), installVNCPanelSubscription()
Sources/TabManager.swift               — openVNC()
Sources/ContentView.swift              — Command palette entry + handler
Package.swift                          — RoyalVNCKit dependency
GhosttyTabs.xcodeproj                  — File refs, SPM package, build phases
```

---

## Phase 2 - Connection Polish (Next)

### 2.1 Connection Reliability
- [ ] Auto-reconnect on disconnect with exponential backoff
- [ ] Connection timeout handling (currently hangs if server doesn't respond)
- [ ] Verify VNCCAFramebufferView is properly receiving framebuffer after connection
- [ ] Debug logging toggle in VNC panel settings
- [ ] Handle server-initiated disconnect gracefully

### 2.2 Connection Dialog Improvements
- [ ] Remember last-used host/port/user per workspace
- [ ] Save credentials securely in Keychain (not plaintext)
- [ ] Connection history dropdown (recent servers)
- [ ] Test connection button (ping/check port before full VNC handshake)

### 2.3 Auth Types
- [x] VNC Password auth
- [x] Apple Remote Desktop (username + password)
- [x] UltraVNC MS-Logon II
- [ ] TLS/SSL wrapped connections
- [ ] SSH tunnel integration (reuse cmux's existing SSH proxy)

---

## Phase 3 - Input & Interaction

### 3.1 Mouse Support
- [ ] Mouse movement tracking in VNCCAFramebufferView
- [ ] Left/right/middle click forwarding
- [ ] Scroll wheel forwarding
- [ ] Mouse cursor rendering (local vs remote cursor)

### 3.2 Keyboard Support
- [ ] Key press/release forwarding via VNCCAFramebufferView
- [ ] Modifier keys (Cmd/Ctrl/Alt/Shift)
- [ ] Special keys (F1-F12, arrows, Home/End, etc.)
- [ ] Ctrl+Alt+Del / special key combos
- [ ] Key mapping for different keyboard layouts

### 3.3 Clipboard
- [x] RoyalVNCKit has clipboard support enabled in settings
- [ ] Verify bidirectional clipboard works (local <-> remote)
- [ ] Clipboard content type support (text only initially)

---

## Phase 4 - UX Polish

### 4.1 Display
- [ ] Scaling modes: Fit to window, 1:1, custom zoom
- [ ] Display quality selector (color depth, compression)
- [ ] Fullscreen support
- [ ] Multi-monitor support (ExtendedDesktopSize encoding)

### 4.2 Tab & Sidebar Integration
- [ ] VNC connection status indicator in tab (connected/disconnected icon)
- [ ] Sidebar entry showing active VNC connections
- [ ] Right-click context menu (disconnect, reconnect, properties)
- [ ] Drag-and-drop file transfer (if protocol supports)

### 4.3 Session Persistence
- [ ] Save VNC connections across app restarts
- [ ] Restore VNC tabs on session restore (reconnect automatically)
- [ ] Connection profiles (saved server configs)

---

## Phase 5 - CLI Integration

### 5.1 Commands
- [ ] `cmux vnc <host>:<port>` — open VNC panel via CLI
- [ ] `cmux vnc --split <host>:<port>` — open as split pane
- [ ] `cmux vnc list` — list active VNC connections
- [ ] `cmux vnc screenshot <surface>` — capture VNC framebuffer

### 5.2 Socket API (v2 JSON-RPC)
- [ ] `vnc.connect` — create VNC panel
- [ ] `vnc.disconnect` — close VNC connection
- [ ] `vnc.status` — get connection state
- [ ] `vnc.screenshot` — capture framebuffer as PNG

---

## Phase 6 - Cross-Platform & Mobile

### 6.1 Mobile VNC UI (iOS/iPadOS via lecoder-mconnect)
- [ ] Touch-to-mouse translation (tap = click, long press = right click)
- [ ] Pinch-to-zoom for framebuffer scaling
- [ ] Two-finger scroll = mouse scroll
- [ ] On-screen keyboard for key input
- [ ] Edge swipe for special keys (Ctrl, Alt, etc.)
- [ ] Trackpad mode (two-finger drag = mouse move)

### 6.2 Cross-Platform Considerations
- [ ] RoyalVNCKit supports macOS, iOS, iPadOS, Linux, Windows, Android
- [ ] Abstract platform-specific view (NSView vs UIView)
- [ ] Touch input translation layer
- [ ] Network discovery (mDNS/Bonjour for local VNC servers)

---

## Phase 7 - SSH-Tunneled VNC

### 7.1 Integration with cmux SSH
- [ ] `cmux ssh user@host --vnc` — SSH + auto-forward VNC port
- [ ] Reuse cmux's existing SSH SOCKS proxy for VNC traffic
- [ ] Auto-detect VNC server on remote host
- [ ] Secure VNC over SSH tunnel (no separate VNC encryption needed)

### 7.2 Remote Desktop Gateway
- [ ] Connect to VNC servers behind NAT via SSH jump hosts
- [ ] Multi-hop: SSH to bastion -> forward VNC from internal host
- [ ] Integrate with Tailscale/WireGuard for mesh VPN access

---

## Dependencies
- **RoyalVNCKit** v1.1.0 (MIT license) — github.com/royalapplications/royalvnc
  - CryptoSwift (fork by royalapplications)
  - Cstb (stb_image for JPEG decoding)
- **Supported encodings**: Tight, ZRLE, CopyRect, Zlib, Hextile, CoRRE, RRE, Raw
- **Supported auth**: None, VNC Password, Apple Remote Desktop, UltraVNC MS-Logon II

## Build
```bash
cd ~/ZenflowProjects/cmux
./scripts/reload.sh --tag arya-vnc --launch
```

## Testing
1. Enable macOS Remote Management: System Settings > Sharing > Remote Management
2. Open arya-cmux DEV
3. Cmd+Shift+P > "vnc" > "New Tab (VNC Remote Desktop)"
4. Enter host/port/user/pass > Connect
5. Verify framebuffer renders, mouse/keyboard works
