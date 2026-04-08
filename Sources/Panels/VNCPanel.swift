import Foundation
import Combine
import AppKit
import RoyalVNCKit

/// Scaling mode for VNC framebuffer display.
enum VNCScalingMode: String, CaseIterable, Identifiable {
    /// Scale framebuffer to fit the available window area (maintains aspect ratio).
    case fitToWindow = "Fit"
    /// Display framebuffer at native resolution with scroll navigation and pinch-to-zoom.
    case actualSize = "1:1"

    var id: String { rawValue }
}

/// A panel that displays a remote desktop via the VNC/RFB protocol.
@MainActor
final class VNCPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .vnc

    /// VNC server hostname or IP.
    @Published var hostname: String

    /// VNC server port (default: 5900).
    @Published var port: UInt16

    /// Username for ARD auth.
    @Published var username: String = ""

    /// Password for VNC/ARD auth.
    @Published var password: String = ""

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Display title shown in the tab bar.
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "display" }

    /// Current connection status.
    @Published private(set) var connectionStatus: String = "Disconnected"

    /// Error message if connection failed.
    @Published private(set) var errorMessage: String?

    /// Whether the connection is active.
    @Published private(set) var isConnected: Bool = false

    /// Whether the panel has previously connected (for showing reconnect button).
    @Published private(set) var hasConnectedBefore: Bool = false

    /// Whether a connection attempt is currently in progress.
    @Published private(set) var isConnecting: Bool = false

    /// The framebuffer — set when the server sends one.
    @Published private(set) var framebuffer: VNCFramebuffer?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Connection duration in seconds (updated every second while connected).
    @Published private(set) var connectionDuration: TimeInterval = 0

    /// Display scaling mode (Fit to Window or Actual Size with scroll/zoom).
    @Published var scalingMode: VNCScalingMode = .fitToWindow

    /// Color depth for the next connection (change takes effect on reconnect).
    @Published var selectedColorDepth: VNCConnection.Settings.ColorDepth = .depth24Bit

    /// The VNC connection object.
    private(set) var connection: VNCConnection?

    /// The framebuffer view (macOS NSView subclass from RoyalVNCKit).
    private(set) var framebufferView: VNCCAFramebufferView?

    private var isClosed: Bool = false

    /// Connection timeout in seconds.
    private let connectionTimeout: TimeInterval = 30

    /// Task for the connection timeout.
    private var timeoutTask: Task<Void, Never>?

    /// Timer for tracking connection duration.
    private var durationTimer: Timer?

    /// Timestamp when the connection was established.
    private var connectedAt: Date?

    /// Recent connections for the connection form dropdown.
    @Published var recentConnections: [VNCRecentConnection] = []

    // MARK: - Init

    init(workspaceId: UUID, hostname: String, port: UInt16 = 5900) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.hostname = hostname
        self.port = port
        self.displayTitle = "\(hostname):\(String(port))"
        // Pre-fill username with current macOS user (editable in the form)
        self.username = NSUserName()
        // Load recent connections and auto-fill from Keychain
        self.recentConnections = VNCRecentConnections.load()
        autoFillFromKeychain()
    }

    // MARK: - Connection lifecycle

    /// Start the VNC connection with current host/port/credentials.
    func connect() {
        guard !isClosed, !isConnecting else { return }
        errorMessage = nil

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: hostname,
            port: port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: selectedColorDepth,
            frameEncodings: [.tight, .zrle, .copyRect, .zlib, .hextile, .raw]
        )

        let conn = VNCConnection(settings: settings)
        conn.delegate = self
        self.connection = conn

        isConnecting = true
        connectionStatus = "Connecting..."
        displayTitle = "\(hostname):\(String(port))"
        conn.connect()

        // Start connection timeout
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, connectionTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(connectionTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.isConnecting else { return }
            self.errorMessage = "Connection timed out after \(Int(connectionTimeout))s"
            self.connectionStatus = "Connection failed"
            self.isConnecting = false
            self.connection?.disconnect()
            self.connection = nil
        }
    }

    /// Disconnect from the VNC server.
    func disconnect() {
        cancelTimeout()
        stopDurationTimer()
        connection?.disconnect()
        connection = nil
        framebufferView = nil
        framebuffer = nil
        isConnected = false
        isConnecting = false
        connectionStatus = "Disconnected"
        displayTitle = hasConnectedBefore
            ? "\(hostname):\(String(port)) (disconnected)"
            : "\(hostname):\(String(port))"
    }

    /// Reconnect to the last-used server.
    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - Timeout & Timer

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func startDurationTimer() {
        connectedAt = Date()
        connectionDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let connectedAt = self.connectedAt else { return }
                self.connectionDuration = Date().timeIntervalSince(connectedAt)
                self.updateConnectedTitle()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        connectedAt = nil
        connectionDuration = 0
    }

    private func updateConnectedTitle() {
        let minutes = Int(connectionDuration) / 60
        let seconds = Int(connectionDuration) % 60
        let durationStr = minutes > 0
            ? String(format: "%d:%02d", minutes, seconds)
            : "\(seconds)s"

        if let fb = framebuffer {
            let size = fb.size
            displayTitle = "\(hostname) (\(Int(size.width))x\(Int(size.height))) \(durationStr)"
        } else {
            displayTitle = "\(hostname):\(String(port)) \(durationStr)"
        }
    }

    // MARK: - Keychain & Recents

    /// Auto-fill password from Keychain for the current host:port.
    func autoFillFromKeychain() {
        if let saved = VNCKeychainStore.loadPassword(host: hostname, port: port) {
            password = saved
        }
    }

    /// Apply a recent connection profile to the form fields.
    func applyRecentConnection(_ recent: VNCRecentConnection) {
        hostname = recent.hostname
        port = recent.port
        username = recent.username
        password = ""
        autoFillFromKeychain()
        displayTitle = "\(hostname):\(String(port))"
    }

    /// Save credentials after a successful connection.
    private func saveCredentials() {
        VNCKeychainStore.savePassword(password, host: hostname, port: port)
        VNCRecentConnections.upsert(VNCRecentConnection(
            hostname: hostname,
            port: port,
            username: username
        ))
        recentConnections = VNCRecentConnections.load()
    }

    // MARK: - Remote key combos

    /// Send Ctrl+Alt+Del to the remote server (useful for Windows VMs).
    func sendCtrlAltDel() {
        guard let connection, isConnected else { return }
        connection.keyDown(.control)
        connection.keyDown(.option)
        connection.keyDown(.forwardDelete)
        connection.keyUp(.forwardDelete)
        connection.keyUp(.option)
        connection.keyUp(.control)
    }

    // MARK: - Panel protocol

    func focus() {
        guard let view = framebufferView,
              let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func unfocus() {
        guard let view = framebufferView,
              let window = view.window,
              window.firstResponder === view else { return }
        window.makeFirstResponder(nil)
    }

    func close() {
        isClosed = true
        cancelTimeout()
        stopDurationTimer()
        disconnect()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Screenshot

    /// Capture the current VNC framebuffer as PNG data. Returns nil if not connected or no framebuffer.
    func captureScreenshot() -> Data? {
        guard let framebufferView else { return nil }
        guard let layer = framebufferView.layer else { return nil }

        let scale = framebufferView.window?.backingScaleFactor ?? 2.0
        let size = framebufferView.bounds.size
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)

        guard let cgImage = context.makeImage() else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    /// Connection status info for socket API queries.
    var statusInfo: [String: Any] {
        var info: [String: Any] = [
            "hostname": hostname,
            "port": Int(port),
            "connected": isConnected,
            "connecting": isConnecting,
            "status": connectionStatus,
        ]
        if !username.isEmpty {
            info["username"] = username
        }
        if let errorMessage {
            info["error"] = errorMessage
        }
        if isConnected {
            info["duration_seconds"] = Int(connectionDuration)
        }
        if let fb = framebuffer {
            let size = fb.size
            info["framebuffer_width"] = Int(size.width)
            info["framebuffer_height"] = Int(size.height)
        }
        info["scaling_mode"] = scalingMode.rawValue
        return info
    }
}

// MARK: - VNCConnectionDelegate

extension VNCPanel: VNCConnectionDelegate {
    nonisolated func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        Task { @MainActor in
            switch connectionState.status {
            case .connecting:
                connectionStatus = "Connecting..."
                isConnecting = true
                errorMessage = nil
            case .connected:
                cancelTimeout()
                connectionStatus = "Connected"
                isConnected = true
                isConnecting = false
                hasConnectedBefore = true
                errorMessage = nil
                startDurationTimer()
                saveCredentials()
            case .disconnected:
                cancelTimeout()
                stopDurationTimer()
                isConnected = false
                isConnecting = false
                if let error = connectionState.error {
                    errorMessage = vncErrorDescription(error)
                    connectionStatus = "Connection failed"
                } else if hasConnectedBefore {
                    connectionStatus = "Disconnected"
                } else {
                    connectionStatus = "Disconnected"
                }
                displayTitle = hasConnectedBefore
                    ? "\(hostname):\(String(port)) (disconnected)"
                    : "\(hostname):\(String(port))"
            @unknown default:
                connectionStatus = "Unknown"
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor in
            switch authenticationType {
            case .vnc:
                if !self.password.isEmpty {
                    completion(VNCPasswordCredential(password: self.password))
                } else {
                    self.cancelTimeout()
                    self.isConnecting = false
                    self.errorMessage = "VNC password required"
                    self.connectionStatus = "Auth required"
                    completion(nil)
                }
            case .appleRemoteDesktop:
                if !self.username.isEmpty && !self.password.isEmpty {
                    completion(VNCUsernamePasswordCredential(
                        username: self.username,
                        password: self.password
                    ))
                } else {
                    self.cancelTimeout()
                    self.isConnecting = false
                    self.errorMessage = "Username and password required for Apple Remote Desktop"
                    self.connectionStatus = "Auth required"
                    completion(nil)
                }
            case .ultraVNCMSLogonII:
                if !self.username.isEmpty && !self.password.isEmpty {
                    completion(VNCUsernamePasswordCredential(
                        username: self.username,
                        password: self.password
                    ))
                } else {
                    self.cancelTimeout()
                    self.isConnecting = false
                    self.errorMessage = "Username and password required"
                    self.connectionStatus = "Auth required"
                    completion(nil)
                }
            @unknown default:
                self.cancelTimeout()
                self.isConnecting = false
                self.errorMessage = "Unsupported authentication type"
                completion(nil)
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor in
            self.framebuffer = framebuffer
            updateConnectedTitle()

            // Create the framebuffer view now
            let view = VNCCAFramebufferView(
                frame: .zero,
                framebuffer: framebuffer,
                connection: connection,
                connectionDelegate: self
            )
            self.framebufferView = view
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor in
            self.framebuffer = framebuffer
            updateConnectedTitle()
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // VNCCAFramebufferView handles rendering updates internally
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        // VNCCAFramebufferView handles cursor updates internally
    }
}

// MARK: - Error description helper

private func vncErrorDescription(_ error: Error) -> String {
    guard let vncError = error as? VNCError else {
        return error.localizedDescription
    }

    guard vncError.shouldDisplayToUser else { return "" }

    switch vncError {
    case .authentication(let authError):
        switch authError {
        case .ardAuthenticationFailed:
            return "Apple Remote Desktop auth failed — check username and password"
        case .noAuthenticationDataProvided:
            return "No credentials provided — enter username and password"
        case .serverOfferedNoAuthTypes:
            return "Server rejected the connection — VNC may not be enabled on the remote host"
        case .securityHandshakingFailed(let reason):
            let base = "Security handshake failed"
            return reason.map { "\(base): \($0)" } ?? base
        case .clientCouldNotDecideOnSecurityType:
            return "Incompatible auth type — the server uses a proprietary security protocol (e.g. RealVNC). Switch to standard VNC password auth or use TigerVNC/x11vnc on the remote host"
        case .encryptionFailed:
            return "Encryption failed during authentication"
        case .ultraVNCMSLogonIIAuthenticationFailed:
            return "UltraVNC authentication failed — check credentials"
        @unknown default:
            return authError.localizedDescription
        }
    case .connection(let connError):
        switch connError {
        case .closed, .cancelled:
            return ""
        case .notReady:
            return "Connection not ready — try again"
        case .closedDuringHandshake(let phase, _):
            return "Connection closed during \(phase) — server may have rejected the connection"
        case .failed(let underlying):
            if let posixError = underlying as? POSIXError {
                switch posixError.code {
                case .ECONNREFUSED:
                    return "Connection refused — verify VNC is running on \(posixError.localizedDescription)"
                case .ETIMEDOUT:
                    return "Connection timed out — check network and firewall settings"
                case .ENETUNREACH, .EHOSTUNREACH:
                    return "Host unreachable — check network connectivity"
                default:
                    return "Connection failed: \(posixError.localizedDescription)"
                }
            }
            let desc = underlying?.localizedDescription ?? "unknown error"
            return "Connection failed: \(desc)"
        @unknown default:
            return connError.localizedDescription
        }
    case .protocol(let protoError):
        return "Protocol error: \(protoError.localizedDescription)"
    @unknown default:
        return vncError.localizedDescription
    }
}
