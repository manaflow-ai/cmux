import AppKit
import CMUXVNC
import Combine
import Foundation

struct VNCDisplayFrame: Equatable {
    let header: VNCFrameHeader
    let payload: Data
}

enum VNCConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

@MainActor
final class VNCPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .vnc
    private(set) var workspaceId: UUID
    let session: MacfleetVNCSession
    let credential: VNCResolvedCredential

    @Published private(set) var displayTitle: String
    @Published private(set) var connectionState: VNCConnectionState = .idle
    @Published private(set) var latestFrame: VNCDisplayFrame?
    @Published private(set) var focusFlashToken: Int = 0

    private weak var focusView: NSView?
    private var connection: VNCPanelConnection?
    private var connectionID: UUID?
    private var restartDates: [Date] = []
    private let restartPolicy = VNCHelperRestartPolicy()

    init(
        workspaceId: UUID,
        session: MacfleetVNCSession,
        credential: VNCResolvedCredential
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.session = session
        self.credential = credential
        self.displayTitle = session.workspaceTitle
    }

    var displayIcon: String? { "display" }

    func attachFocusView(_ view: NSView?) {
        focusView = view
    }

    func startIfNeeded() {
        guard connection == nil else { return }
        connectionState = .connecting
        let nextConnectionID = UUID()
        connectionID = nextConnectionID
        let nextConnection = VNCPanelConnection(
            session: session,
            credential: credential,
            onControl: { [weak self] control in
                guard self?.connectionID == nextConnectionID else { return }
                self?.handleControl(control)
            },
            onFrame: { [weak self] header, payload in
                guard self?.connectionID == nextConnectionID else { return }
                self?.latestFrame = VNCDisplayFrame(header: header, payload: payload)
            },
            onExit: { [weak self] reason, shouldRestart in
                guard let self, self.connectionID == nextConnectionID else { return }
                if case .disconnected = self.connectionState {
                    self.connection = nil
                    self.connectionID = nil
                    return
                }
                self.connection = nil
                self.connectionID = nil
                if shouldRestart, self.restartAfterUnexpectedExit(reason: reason) {
                    return
                }
                self.connectionState = .failed(reason)
            }
        )
        connection = nextConnection
        nextConnection.start()
    }

    func reconnect() {
        connection?.close()
        connection = nil
        connectionID = nil
        restartDates.removeAll()
        latestFrame = nil
        startIfNeeded()
    }

    func setVisible(_ isVisible: Bool) {
        connection?.sendControl(VNCControlMessage(kind: "visibility", visible: isVisible))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        startIfNeeded()
        connection?.sendControl(VNCControlMessage(kind: "text", text: text))
    }

    func sendKey(keyCode: UInt16, isDown: Bool) {
        startIfNeeded()
        connection?.sendControl(VNCControlMessage(kind: "key", isDown: isDown, keyCode: Int(keyCode)))
    }

    func sendPointer(x: Int, y: Int, button: Int, isDown: Bool) {
        startIfNeeded()
        connection?.sendControl(VNCControlMessage(kind: "pointer", x: x, y: y, button: button, isDown: isDown))
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> Bool {
        guard let keyCode = Self.keyCode(for: keyName) else { return false }
        sendKey(keyCode: keyCode, isDown: true)
        sendKey(keyCode: keyCode, isDown: false)
        return true
    }

    func close() {
        connection?.close()
        connection = nil
        connectionID = nil
        focusView = nil
    }

    func focus() {
        guard let view = focusView, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard let focusView,
              responder === focusView || responder.isDescendant(of: focusView) else {
            return nil
        }
        return .panel
    }

    private func handleControl(_ control: VNCControlMessage) {
        switch control.state {
        case "connecting":
            connectionState = .connecting
        case "connected":
            connectionState = .connected
        case "disconnected":
            connectionState = .disconnected
        case "failed":
            connectionState = .failed(control.message ?? VNCPanelText.stateFailed)
        default:
            break
        }
    }

    private func restartAfterUnexpectedExit(reason: String) -> Bool {
        let now = Date()
        guard restartPolicy.canRestart(previousRestartDates: restartDates, now: now) else {
            connectionState = .failed(reason)
            return false
        }
        restartDates = restartPolicy.recordRestart(previousRestartDates: restartDates, now: now)
        latestFrame = nil
        connectionState = .connecting
        startIfNeeded()
        return true
    }

    private static func keyCode(for keyName: String) -> UInt16? {
        switch keyName.lowercased() {
        case "enter", "return":
            return 36
        case "tab":
            return 48
        case "escape", "esc":
            return 53
        case "backspace":
            return 51
        case "delete", "del", "forward_delete":
            return 117
        case "space":
            return 49
        case "left", "arrow_left", "arrowleft":
            return 123
        case "right", "arrow_right", "arrowright":
            return 124
        case "down", "arrow_down", "arrowdown":
            return 125
        case "up", "arrow_up", "arrowup":
            return 126
        case "home":
            return 115
        case "end":
            return 119
        case "pageup", "page_up":
            return 116
        case "pagedown", "page_down":
            return 121
        default:
            return nil
        }
    }
}

private extension NSResponder {
    func isDescendant(of view: NSView) -> Bool {
        var responder: NSResponder? = self
        while let current = responder {
            if current === view { return true }
            responder = current.nextResponder
        }
        return false
    }
}
