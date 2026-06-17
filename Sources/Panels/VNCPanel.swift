import AppKit
import Combine
import CmuxVNC
import Foundation

/// Connection state for a ``VNCPanel``, surfaced to the view for status UI.
enum VNCConnectionState: Equatable {
    case authenticating
    case connecting
    case connected
    case disconnected(String?)
}

/// A native VNC (RFB) viewer surface. Renders a remote framebuffer with the
/// `CmuxVNC` engine (no WebKit, no system Screen Sharing app) and forwards
/// mouse/keyboard input. The panel owns the live session so split/tab layout
/// churn never tears down or reconnects the stream.
@MainActor
final class VNCPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .vnc

    private(set) var workspaceId: UUID

    /// The remote target as supplied (may have no password). Frozen for the life
    /// of the panel; reconnect/unlock reuses it.
    let endpoint: VNCEndpoint

    /// Tab title: the server's desktop name once known, else `host:port`.
    @Published private(set) var displayTitle: String

    @Published private(set) var connectionState: VNCConnectionState = .connecting

    /// Whether a Touch ID-gated password is stored for this host, enabling the
    /// "Unlock" / "Forget" affordances.
    @Published private(set) var hasSavedPassword: Bool = false

    /// Bumped each time a fresh session is built so the host view recreates the
    /// native surface (which owns the new client).
    @Published private(set) var sessionToken: Int = 0

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "display" }

    /// The current native surface view, owned here so it outlives view churn.
    private(set) var surfaceView: VNCSurfaceView

    private var isClosed = false
    /// Set when the active session used an inline password we should persist on
    /// a successful connect (Touch ID-gated thereafter).
    private var passwordToSaveOnConnect: String?

    init(workspaceId: UUID, endpoint: VNCEndpoint, autoConnect: Bool = true) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.endpoint = endpoint
        self.displayTitle = endpoint.displayLabel
        self.hasSavedPassword = VNCCredentialStore.hasCredential(host: endpoint.host, port: endpoint.port)
        // A placeholder session; `beginConnect()` builds the real one (possibly
        // after a Touch ID unlock).
        self.surfaceView = VNCSurfaceView(client: RFBClient(endpoint: endpoint))
        configure(surfaceView)
        if autoConnect {
            beginConnect()
        }
    }

    private func configure(_ view: VNCSurfaceView) {
        view.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// The endpoint string for persistence, e.g. `vnc://user@host:5901`. The
    /// password is never persisted in the session snapshot (it lives in the
    /// Keychain instead).
    var persistableConnectionString: String {
        if let username = endpoint.username, !username.isEmpty {
            return "vnc://\(username)@\(endpoint.host):\(endpoint.port)"
        }
        return "vnc://\(endpoint.host):\(endpoint.port)"
    }

    // MARK: - Connection

    /// Decides how to connect: directly with an inline password, by unlocking a
    /// saved password via Touch ID, or anonymously.
    private func beginConnect() {
        guard !isClosed else { return }
        if let password = endpoint.password, !password.isEmpty {
            // Inline password: connect now and remember it on success.
            passwordToSaveOnConnect = password
            startSession(with: endpoint)
        } else if VNCCredentialStore.hasCredential(host: endpoint.host, port: endpoint.port) {
            unlockAndConnect()
        } else {
            passwordToSaveOnConnect = nil
            startSession(with: endpoint)
        }
    }

    /// Prompts for Touch ID, then connects with the unlocked password.
    private func unlockAndConnect() {
        connectionState = .authenticating
        let host = endpoint.host
        let port = endpoint.port
        let reason = String(
            localized: "vnc.touchid.reason",
            defaultValue: "unlock the saved VNC password"
        )
        Task { [weak self] in
            let password = await VNCCredentialStore.load(host: host, port: port, reason: reason)
            guard let self, !self.isClosed else { return }
            guard let password else {
                self.connectionState = .disconnected(String(
                    localized: "vnc.status.touchidRequired",
                    defaultValue: "Touch ID is required to unlock the saved password."
                ))
                return
            }
            self.passwordToSaveOnConnect = nil // already stored
            self.startSession(with: self.endpointWithPassword(password))
        }
    }

    private func endpointWithPassword(_ password: String) -> VNCEndpoint {
        VNCEndpoint(host: endpoint.host, port: endpoint.port, password: password, username: endpoint.username)
    }

    /// Tears down any current session and starts a fresh one.
    private func startSession(with endpoint: VNCEndpoint) {
        surfaceView.disconnect()
        let view = VNCSurfaceView(client: RFBClient(endpoint: endpoint))
        configure(view)
        surfaceView = view
        sessionToken += 1
        connectionState = .connecting
        view.connect()
    }

    /// Reconnect affordance after a drop: re-runs the full decision (Touch ID if needed).
    func reconnect() {
        guard !isClosed else { return }
        beginConnect()
    }

    /// Forget the stored password for this host.
    func forgetSavedPassword() {
        VNCCredentialStore.delete(host: endpoint.host, port: endpoint.port)
        hasSavedPassword = false
    }

    private func handle(_ event: VNCClientEvent) {
        switch event {
        case .connecting:
            if connectionState != .authenticating {
                connectionState = .connecting
            }
        case .connected(_, _, let name):
            connectionState = .connected
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                displayTitle = trimmed
            }
            // Persist a working inline password, Touch ID-gated for next time.
            if let password = passwordToSaveOnConnect {
                VNCCredentialStore.save(host: endpoint.host, port: endpoint.port, password: password)
                passwordToSaveOnConnect = nil
                hasSavedPassword = true
            }
        case .disconnected(let error):
            connectionState = .disconnected(error?.errorDescription)
        case .bell:
            NSSound.beep()
        case .frame, .resized, .serverCutText:
            break
        }
    }

    // MARK: - Panel protocol

    func focus() {
        guard !isClosed else { return }
        _ = surfaceView.window?.makeFirstResponder(surfaceView)
    }

    func unfocus() {
        // No panel-local first responder to relinquish beyond the surface itself.
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        surfaceView.disconnect()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
