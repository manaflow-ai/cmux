import AppKit
import Combine
import CmuxVNC
import Foundation

/// Connection state for a ``VNCPanel``, surfaced to the view for status UI.
enum VNCConnectionState: Equatable {
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

    /// The remote target. Frozen for the life of the panel; reconnect reuses it.
    let endpoint: VNCEndpoint

    /// Tab title: the server's desktop name once known, else `host:port`.
    @Published private(set) var displayTitle: String

    @Published private(set) var connectionState: VNCConnectionState = .connecting

    /// Bumped each time a fresh session is built so the host view recreates the
    /// native surface (which owns the new client).
    @Published private(set) var sessionToken: Int = 0

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "display" }

    /// The current native surface view, owned here so it outlives view churn.
    private(set) var surfaceView: VNCSurfaceView

    private var isClosed = false

    init(workspaceId: UUID, endpoint: VNCEndpoint, autoConnect: Bool = true) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.endpoint = endpoint
        self.displayTitle = endpoint.displayLabel
        self.surfaceView = VNCSurfaceView(client: RFBClient(endpoint: endpoint))
        configure(surfaceView)
        if autoConnect {
            connect()
        }
    }

    private func configure(_ view: VNCSurfaceView) {
        view.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// The endpoint string for persistence, e.g. `vnc://host:5901`. Password is
    /// intentionally never persisted.
    var persistableConnectionString: String {
        "vnc://\(endpoint.host):\(endpoint.port)"
    }

    // MARK: - Connection

    func connect() {
        guard !isClosed else { return }
        connectionState = .connecting
        surfaceView.connect()
    }

    /// Tears down the current session and starts a fresh one against the same
    /// endpoint. Used by the "Reconnect" affordance after a drop.
    func reconnect() {
        guard !isClosed else { return }
        surfaceView.disconnect()
        let view = VNCSurfaceView(client: RFBClient(endpoint: endpoint))
        configure(view)
        surfaceView = view
        sessionToken += 1
        connectionState = .connecting
        view.connect()
    }

    private func handle(_ event: VNCClientEvent) {
        switch event {
        case .connecting:
            connectionState = .connecting
        case .connected(_, _, let name):
            connectionState = .connected
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                displayTitle = trimmed
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
