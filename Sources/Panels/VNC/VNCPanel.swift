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

enum VNCInputResult: Equatable {
    case sent
    case unavailable
    case unknownKey
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
                self?.applyFrame(header: header, payload: payload)
            },
            onExit: { [weak self] exit in
                guard let self, self.connectionID == nextConnectionID else { return }
                self.connection = nil
                self.connectionID = nil
                switch exit {
                case .disconnected:
                    self.connectionState = .disconnected
                    return
                case .failure(let reason, let shouldRestart):
                    if shouldRestart, self.restartAfterUnexpectedExit(reason: reason) {
                        return
                    }
                    self.connectionState = .failed(reason)
                }
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

    @discardableResult
    func sendText(_ text: String) -> VNCInputResult {
        guard !text.isEmpty else { return .sent }
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "text", text: text))
        return .sent
    }

    @discardableResult
    func sendKey(keyCode: UInt16, isDown: Bool) -> VNCInputResult {
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "key", isDown: isDown, keyCode: Int(keyCode)))
        return .sent
    }

    @discardableResult
    func sendPointer(x: Int, y: Int, button: Int? = nil, isDown: Bool? = nil) -> VNCInputResult {
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "pointer", x: x, y: y, button: button, isDown: isDown))
        return .sent
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> VNCInputResult {
        guard let keyCode = Self.keyCode(for: keyName) else { return .unknownKey }
        guard sendKey(keyCode: keyCode, isDown: true) == .sent else { return .unavailable }
        return sendKey(keyCode: keyCode, isDown: false)
    }

    func close() {
        connection?.close()
        connection = nil
        connectionID = nil
        focusView = nil
        latestFrame = nil
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

    private func applyFrame(header: VNCFrameHeader, payload: Data) {
        latestFrame = VNCDisplayFrame(header: header, payload: payload)
    }

    private func prepareForUserInput() -> Bool {
        if connection != nil { return true }
        guard connectionState == .idle else { return false }
        startIfNeeded()
        return connection != nil
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
