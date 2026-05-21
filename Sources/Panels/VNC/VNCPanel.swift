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

struct VNCNamedKeyStroke: Equatable {
    let modifierKeyCodes: [UInt16]
    let keyCode: UInt16
}

@MainActor
final class VNCPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .vnc
    private(set) var workspaceId: UUID
    let session: MacfleetVNCSession
    private var credential: VNCResolvedCredential?

    @Published private(set) var displayTitle: String
    @Published private(set) var connectionState: VNCConnectionState = .idle
    @Published private(set) var hasFrame = false
    @Published private(set) var focusFlashToken: Int = 0

    private weak var focusView: NSView?
    private var pendingFocus = false
    private var connection: VNCPanelConnection?
    private var connectionID: UUID?
    private var restartDates: [Date] = []
    private let restartPolicy = VNCHelperRestartPolicy()
    private var replayFramebuffer = Data()
    private var replayFramebufferWidth = 0
    private var replayFramebufferHeight = 0
    private var replayFrameSequence: UInt64 = 0
    private var frameHandlers: [UUID: (VNCDisplayFrame?) -> Void] = [:]
    private var desiredVisibility = false
    private var credentialResolutionID: UUID?

    init(
        workspaceId: UUID,
        session: MacfleetVNCSession,
        credential: VNCResolvedCredential?
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
        applyPendingFocusIfPossible()
    }

    func focusViewWindowDidChange(_ view: NSView) {
        guard view === focusView else { return }
        applyPendingFocusIfPossible()
    }

    func startIfNeeded() {
        guard connection == nil else { return }
        guard let credential else {
            resolveCredentialAndStartIfNeeded()
            return
        }
        startConnection(credential: credential)
    }

    private func resolveCredentialAndStartIfNeeded() {
        guard credentialResolutionID == nil else { return }
        connectionState = .connecting
        let resolutionID = UUID()
        credentialResolutionID = resolutionID
        let session = session
        Task { [weak self] in
            let resolvedCredential = await VNCSessionCredentialProvider.credentialOffMainActor(for: session)
            await MainActor.run {
                guard let self, self.credentialResolutionID == resolutionID else { return }
                self.credentialResolutionID = nil
                guard self.connection == nil else { return }
                guard let resolvedCredential else {
                    self.connectionState = .failed(VNCPanelText.macfleetNoCredentialsMessage)
                    return
                }
                self.credential = resolvedCredential
                self.startConnection(credential: resolvedCredential)
            }
        }
    }

    private func startConnection(credential: VNCResolvedCredential) {
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
                self.publishFrame(nil)
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
        sendDesiredVisibility()
        nextConnection.start()
    }

    func reconnect() {
        let closingConnection = connection
        connection = nil
        connectionID = nil
        credentialResolutionID = nil
        restartDates.removeAll()
        publishFrame(nil)
        closingConnection?.close()
        startIfNeeded()
    }

    func setVisible(_ isVisible: Bool) {
        desiredVisibility = isVisible
        sendDesiredVisibility()
    }

    private func sendDesiredVisibility() {
        connection?.sendControl(VNCControlMessage(kind: "visibility", visible: desiredVisibility))
    }

    @discardableResult
    func sendText(_ text: String) -> VNCInputResult {
        guard !text.isEmpty else { return .sent }
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "text", text: text))
        return .sent
    }

    @discardableResult
    func sendKey(keyCode: UInt16, isDown: Bool, text: String? = nil) -> VNCInputResult {
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "key", text: text, isDown: isDown, keyCode: Int(keyCode)))
        return .sent
    }

    @discardableResult
    func sendPointer(x: Int, y: Int, button: Int? = nil, isDown: Bool? = nil) -> VNCInputResult {
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "pointer", x: x, y: y, button: button, isDown: isDown))
        return .sent
    }

    @discardableResult
    func sendWheel(x: Int, y: Int, wheel: Int, steps: Int) -> VNCInputResult {
        guard steps > 0 else { return .sent }
        guard prepareForUserInput() else { return .unavailable }
        connection?.sendControl(VNCControlMessage(kind: "wheel", x: x, y: y, wheel: wheel, steps: steps))
        return .sent
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> VNCInputResult {
        guard let keyStroke = Self.namedKeyStroke(for: keyName) else { return .unknownKey }

        var pressedModifiers: [UInt16] = []
        for modifierKeyCode in keyStroke.modifierKeyCodes {
            guard sendKey(keyCode: modifierKeyCode, isDown: true) == .sent else {
                releaseModifierKeys(pressedModifiers)
                return .unavailable
            }
            pressedModifiers.append(modifierKeyCode)
        }

        guard sendKey(keyCode: keyStroke.keyCode, isDown: true) == .sent else {
            releaseModifierKeys(pressedModifiers)
            return .unavailable
        }
        let upResult = sendKey(keyCode: keyStroke.keyCode, isDown: false)
        let modifierResult = releaseModifierKeys(pressedModifiers)
        return upResult == .sent && modifierResult == .sent ? .sent : .unavailable
    }

    func close() {
        let closingConnection = connection
        connection = nil
        connectionID = nil
        credentialResolutionID = nil
        focusView = nil
        pendingFocus = false
        publishFrame(nil)
        closingConnection?.close()
    }

    func addFrameHandler(_ handler: @escaping (VNCDisplayFrame?) -> Void) -> UUID {
        let id = UUID()
        frameHandlers[id] = handler
        handler(currentReplayFrame())
        return id
    }

    func removeFrameHandler(_ id: UUID?) {
        guard let id else { return }
        frameHandlers[id] = nil
    }

    func focus() {
        pendingFocus = true
        applyPendingFocusIfPossible()
    }

    func unfocus() {
        pendingFocus = false
    }

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
        guard control.kind == "state" else { return }
        switch control.state {
        case "connecting":
            connectionState = .connecting
        case "connected":
            connectionState = .connected
        case "disconnected":
            connectionState = .disconnected
        case "failed":
            connectionState = .failed(VNCPanelText.helperErrorMessage(errorCode: control.errorCode))
        default:
            break
        }
    }

    private func applyFrame(header: VNCFrameHeader, payload: Data) {
        guard updateReplayFramebuffer(header: header, payload: payload) else { return }
        let frame = VNCDisplayFrame(header: header, payload: payload)
        let nextHasFrame = !replayFramebuffer.isEmpty
        if hasFrame != nextHasFrame {
            hasFrame = nextHasFrame
        }
        for handler in frameHandlers.values {
            handler(frame)
        }
    }

    private func publishFrame(_ frame: VNCDisplayFrame?) {
        if frame == nil {
            resetFrameReplay()
        }
        let nextHasFrame = frame != nil
        if hasFrame != nextHasFrame {
            hasFrame = nextHasFrame
        }
        for handler in frameHandlers.values {
            handler(frame)
        }
    }

    private func updateReplayFramebuffer(header: VNCFrameHeader, payload: Data) -> Bool {
        if replayFrameSequence > 0, header.sequence <= replayFrameSequence {
            return false
        }
        guard VNCFrameValidator.validate(header: header, payloadByteCount: payload.count) == nil,
              resizeReplayFramebufferIfNeeded(width: header.framebufferWidth, height: header.framebufferHeight),
              VNCFrameBlitter.copyBGRAFrame(
                header: header,
                payload: payload,
                into: &replayFramebuffer,
                framebufferWidth: replayFramebufferWidth,
                framebufferHeight: replayFramebufferHeight
              ) else {
            return false
        }
        replayFrameSequence = header.sequence
        return true
    }

    private func currentReplayFrame() -> VNCDisplayFrame? {
        guard replayFramebufferWidth > 0,
              replayFramebufferHeight > 0,
              !replayFramebuffer.isEmpty else {
            return nil
        }
        return VNCDisplayFrame(
            header: VNCFrameHeader(
                sequence: replayFrameSequence,
                x: 0,
                y: 0,
                width: replayFramebufferWidth,
                height: replayFramebufferHeight,
                framebufferWidth: replayFramebufferWidth,
                framebufferHeight: replayFramebufferHeight,
                stride: replayFramebufferWidth * 4,
                pixelFormat: .bgra8
            ),
            payload: replayFramebuffer
        )
    }

    private func resetFrameReplay() {
        replayFramebuffer.removeAll(keepingCapacity: false)
        replayFramebufferWidth = 0
        replayFramebufferHeight = 0
        replayFrameSequence = 0
    }

    private func resizeReplayFramebufferIfNeeded(width: Int, height: Int) -> Bool {
        guard let byteCount = Self.framebufferByteCount(width: width, height: height) else {
            return false
        }
        if width == replayFramebufferWidth,
           height == replayFramebufferHeight,
           replayFramebuffer.count == byteCount {
            return true
        }
        replayFramebufferWidth = width
        replayFramebufferHeight = height
        replayFramebuffer = Data(repeating: 0, count: byteCount)
        return true
    }

    private static func framebufferByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let maxPixels = 33_554_432
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixelCount <= maxPixels else { return nil }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow else { return nil }
        return byteCount
    }

    private func applyPendingFocusIfPossible() {
        guard pendingFocus, let view = focusView, let window = view.window else { return }
        if window.makeFirstResponder(view) {
            pendingFocus = false
        }
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
        publishFrame(nil)
        connectionState = .connecting
        startIfNeeded()
        return true
    }

    @discardableResult
    private func releaseModifierKeys(_ modifierKeyCodes: [UInt16]) -> VNCInputResult {
        var result = VNCInputResult.sent
        for modifierKeyCode in modifierKeyCodes.reversed() {
            if sendKey(keyCode: modifierKeyCode, isDown: false) != .sent {
                result = .unavailable
            }
        }
        return result
    }

    static func namedKeyStroke(for keyName: String) -> VNCNamedKeyStroke? {
        let normalized = normalizedKeyName(keyName)
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "sigint":
            return namedKeyStroke(for: "ctrl-c")
        case "eof":
            return namedKeyStroke(for: "ctrl-d")
        case "sigtstp":
            return namedKeyStroke(for: "ctrl-z")
        case "sigquit":
            return namedKeyStroke(for: "ctrl-\\")
        case "backtab":
            return namedKeyStroke(for: "shift-tab")
        default:
            break
        }

        let parts: [String]
        if normalized.contains("+") {
            parts = normalized.split(separator: "+").map(String.init).filter { !$0.isEmpty }
        } else {
            parts = modifierPrefixedParts(from: normalized)
        }
        guard let baseKey = parts.last, !baseKey.isEmpty else { return nil }

        var modifiers: [UInt16] = []
        for modifierName in parts.dropLast() {
            guard let modifierKeyCode = modifierKeyCode(for: modifierName) else { return nil }
            if !modifiers.contains(modifierKeyCode) {
                modifiers.append(modifierKeyCode)
            }
        }
        guard let keyCode = keyCode(for: baseKey) else { return nil }
        return VNCNamedKeyStroke(modifierKeyCodes: modifiers, keyCode: keyCode)
    }

    private static func normalizedKeyName(_ keyName: String) -> String {
        keyName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func modifierPrefixedParts(from normalized: String) -> [String] {
        var remaining = normalized
        var parts: [String] = []
        while let separatorIndex = remaining.firstIndex(of: "-") {
            let prefix = String(remaining[..<separatorIndex])
            guard modifierKeyCode(for: prefix) != nil else { break }
            parts.append(prefix)
            remaining = String(remaining[remaining.index(after: separatorIndex)...])
        }
        parts.append(remaining)
        return parts
    }

    private static func modifierKeyCode(for modifierName: String) -> UInt16? {
        switch modifierName {
        case "shift":
            return 56
        case "ctrl", "control":
            return 59
        case "alt", "opt", "option":
            return 58
        case "cmd", "command", "super", "meta":
            return 55
        default:
            return nil
        }
    }

    private static func keyCode(for keyName: String) -> UInt16? {
        switch keyName.lowercased() {
        case "a":
            return 0
        case "s":
            return 1
        case "d":
            return 2
        case "f":
            return 3
        case "h":
            return 4
        case "g":
            return 5
        case "z":
            return 6
        case "x":
            return 7
        case "c":
            return 8
        case "v":
            return 9
        case "b":
            return 11
        case "q":
            return 12
        case "w":
            return 13
        case "e":
            return 14
        case "r":
            return 15
        case "y":
            return 16
        case "t":
            return 17
        case "1":
            return 18
        case "2":
            return 19
        case "3":
            return 20
        case "4":
            return 21
        case "6":
            return 22
        case "5":
            return 23
        case "=":
            return 24
        case "9":
            return 25
        case "7":
            return 26
        case "-":
            return 27
        case "8":
            return 28
        case "0":
            return 29
        case "]":
            return 30
        case "o":
            return 31
        case "u":
            return 32
        case "[":
            return 33
        case "i":
            return 34
        case "p":
            return 35
        case "enter", "return":
            return 36
        case "l":
            return 37
        case "j":
            return 38
        case "'":
            return 39
        case "k":
            return 40
        case ";":
            return 41
        case "\\":
            return 42
        case ",":
            return 43
        case "/":
            return 44
        case "n":
            return 45
        case "m":
            return 46
        case ".":
            return 47
        case "tab":
            return 48
        case "`":
            return 50
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
