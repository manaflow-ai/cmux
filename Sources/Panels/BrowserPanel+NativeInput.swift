import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// The pointer `browser.input_mouse` keeps per browser panel: where it last
/// moved, which buttons are down, and a queue so one request finishes before
/// the next starts.
@MainActor
final class BrowserRawInputPointerState {
    private(set) var position: CGPoint = .zero
    /// Buttons down in `webView`; a replaced web view never saw the press.
    private var pressed: Set<BrowserReplMouseButton> = []
    private weak var pressedWebView: WKWebView?
    private var tail: Task<Void, Never>?

    func move(to point: CGPoint) { position = point }

    func pressedButtons(in webView: WKWebView) -> Set<BrowserReplMouseButton> {
        pressedWebView === webView ? pressed : []
    }

    func setPressed(_ button: BrowserReplMouseButton, _ isDown: Bool, in webView: WKWebView) {
        if pressedWebView !== webView {
            pressed = []
            pressedWebView = webView
        }
        if isDown { pressed.insert(button) } else { pressed.remove(button) }
    }

    /// Runs `body` after every earlier request of this panel has finished.
    func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Why a raw input request failed after it was read.
enum BrowserRawInputFailure: Error, Sendable {
    case stale
    case timedOut
    case notRenderable
    case dragUnsupported
    case unknownKey(String)
    case eventCreationFailed
}

/// Native input for automation: each ``BrowserRawInputStep`` becomes an
/// AppKit event delivered straight to WebKit (the browser REPL's path), so
/// the page sees trusted DOM events. Nothing focuses the window or moves the
/// real cursor; a hidden pane renders in an offscreen host for the duration.
/// Requests run one at a time per panel, and one that fails or is cancelled
/// releases the buttons it pressed.
extension BrowserPanel {
    /// Delivers `steps` to `webView`, the panel's current web view, after
    /// every earlier native input request of this panel, and returns where
    /// the pointer ends. Throws ``BrowserRawInputFailure``.
    func deliverNativeInput(
        _ steps: [BrowserRawInputStep],
        to webView: WKWebView
    ) async throws -> CGPoint {
        try await browserRawInputPointer.serialized { [self] in
            try await deliverNativeInputNow(steps, to: webView)
        }
    }

    private func deliverNativeInputNow(
        _ steps: [BrowserRawInputStep],
        to webView: WKWebView
    ) async throws -> CGPoint {
        let panel = self
        // Refuse unknown keys before anything reaches the page.
        for step in steps {
            switch step {
            case .keyDown(let key, _), .keyUp(let key, _):
                guard BrowserKeyboardEvent(rawKey: key)?.nativeKey != nil else {
                    throw BrowserRawInputFailure.unknownKey(key)
                }
            default:
                break
            }
        }
        switch await panel.ensureAutomationDocumentReady(
            expectedWebViewIdentifier: ObjectIdentifier(webView),
            reason: "automation-raw-input"
        ) {
        case .committed: break
        case .timedOut: throw BrowserRawInputFailure.timedOut
        case .superseded, .cancelled: throw BrowserRawInputFailure.stale
        }
        guard panel.webView === webView, let cmuxWebView = webView as? CmuxWebView else {
            throw BrowserRawInputFailure.stale
        }
        let state = panel.browserRawInputPointer
        let usesMouse = steps.contains { step in
            switch step {
            case .mouseMoved, .mousePressed, .mouseReleased, .mouseWheel: true
            case .keyDown, .keyUp, .insertText: false
            }
        }
        let pressesRight = steps.contains { step in
            if case .mousePressed(_, .right, _, _) = step { return true }
            return false
        }
        let deliver: @MainActor (NSWindow?) async throws -> Void = { window in
            let alreadyPressed = state.pressedButtons(in: cmuxWebView)
            do {
                for step in steps {
                    try Task.checkCancellation()
                    try await Self.deliverRawInputStep(step, webView: cmuxWebView, window: window, state: state)
                }
            } catch {
                // Never leave a button this request pressed held down.
                let stuck = state.pressedButtons(in: cmuxWebView).subtracting(alreadyPressed)
                for button in stuck {
                    try? Self.releaseButton(button, webView: cmuxWebView, window: window, state: state)
                }
                throw error
            }
            if pressesRight {
                // The page may cancel its context menu, which never reaches
                // `willOpenMenu`; drop the suppression an automated right
                // press arms so the user's next right click still opens one.
                await BrowserReplNativeInput.waitForPendingMouseEvents(cmuxWebView)
                await BrowserReplNativeInput.roundTrip(cmuxWebView)
                cmuxWebView.cancelPendingAutomationContextMenus()
            }
        }
        if !usesMouse {
            try await deliver(cmuxWebView.window)
        } else if let window = cmuxWebView.window {
            try await deliver(window)
        } else {
            try await panel.withBrowserReplRenderHost {
                guard let window = cmuxWebView.window else { throw BrowserRawInputFailure.notRenderable }
                try await deliver(window)
            }
        }
        return state.position
    }

    @MainActor
    private static func deliverRawInputStep(
        _ step: BrowserRawInputStep,
        webView: CmuxWebView,
        window: NSWindow?,
        state: BrowserRawInputPointerState
    ) async throws {
        switch step {
        case .mouseMoved(let location, let modifiers):
            // A move with a button held would let WebKit start a system drag
            // session; only the REPL arms the drag capture that contains it.
            guard state.pressedButtons(in: webView).isEmpty else { throw BrowserRawInputFailure.dragUnsupported }
            let point = location.resolved(pointer: state.position)
            state.move(to: point)
            try Self.sendMouse(.mouseMoved, button: .left, at: point, clickCount: 0, modifiers: modifiers, webView: webView, window: window)
        case .mousePressed(let location, let button, let clickCount, let modifiers):
            let point = location.resolved(pointer: state.position)
            state.move(to: point)
            let type: NSEvent.EventType = switch button {
            case .left: .leftMouseDown
            case .right: .rightMouseDown
            case .middle: .otherMouseDown
            }
            try Self.sendMouse(type, button: button, at: point, clickCount: clickCount, modifiers: modifiers, webView: webView, window: window)
            state.setPressed(button, true, in: webView)
        case .mouseReleased(let location, let button, let clickCount, let modifiers):
            let point = location.resolved(pointer: state.position)
            state.move(to: point)
            try Self.sendMouse(Self.releaseType(button), button: button, at: point, clickCount: clickCount, modifiers: modifiers, webView: webView, window: window)
            state.setPressed(button, false, in: webView)
        case .mouseWheel(let location, let deltaX, let deltaY, let modifiers):
            let point = location.resolved(pointer: state.position)
            guard let window,
                  let event = BrowserReplNativeInput.wheelEvent(
                    webView: webView,
                    window: window,
                    cssPoint: point,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    modifierFlags: Self.modifierFlags(modifiers, webView: webView)
                  ) else {
                throw BrowserRawInputFailure.eventCreationFailed
            }
            state.move(to: point)
            webView.deliverAutomationMouseEvent(event)
            await BrowserReplNativeInput.roundTrip(webView)
            return
        case .keyDown(let key, let modifiers):
            try Self.replayKey(key, action: .keyDown, modifiers: modifiers, webView: webView)
            return
        case .keyUp(let key, let modifiers):
            try Self.replayKey(key, action: .keyUp, modifiers: modifiers, webView: webView)
            return
        case .insertText(let text):
            try await BrowserReplNativeInput.insertText(text, into: webView)
            return
        }
        await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
    }

    private static func releaseType(_ button: BrowserReplMouseButton) -> NSEvent.EventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    /// Releases `button` at the pointer, without a cancellation check.
    @MainActor
    private static func releaseButton(
        _ button: BrowserReplMouseButton,
        webView: CmuxWebView,
        window: NSWindow?,
        state: BrowserRawInputPointerState
    ) throws {
        state.setPressed(button, false, in: webView)
        try Self.sendMouse(Self.releaseType(button), button: button, at: state.position, clickCount: 1, modifiers: [], webView: webView, window: window)
    }

    @MainActor
    private static func sendMouse(
        _ type: NSEvent.EventType,
        button: BrowserReplMouseButton,
        at point: CGPoint,
        clickCount: Int,
        modifiers: BrowserRawInputModifiers,
        webView: CmuxWebView,
        window: NSWindow?
    ) throws {
        guard let window,
              let event = BrowserReplNativeInput.mouseEvent(
                type: type,
                button: button,
                webView: webView,
                window: window,
                cssPoint: point,
                clickCount: clickCount,
                modifierFlags: Self.modifierFlags(modifiers, webView: webView)
              ) else {
            throw BrowserRawInputFailure.eventCreationFailed
        }
        webView.deliverAutomationMouseEvent(event)
    }

    /// Replays one key. A key-down whose `modifiers` name keys that are not
    /// held is wrapped in those modifier keys, as a person would press them;
    /// a modifier key itself and a key-up are sent as they are, so a client
    /// that holds Shift with its own `keyDown Shift` keeps it held.
    @MainActor
    private static func replayKey(
        _ key: String,
        action: BrowserKeyboardAction,
        modifiers: BrowserRawInputModifiers,
        webView: CmuxWebView
    ) throws {
        guard let event = BrowserKeyboardEvent(rawKey: key), let nativeKey = event.nativeKey else {
            throw BrowserRawInputFailure.unknownKey(key)
        }
        var pressed: [BrowserKeyboardEvent] = []
        if action == .keyDown, nativeKey.modifierKey == nil {
            let held = webView.browserNativeInputDeliveryOwner.activeModifierFlags
            let wrappers: [(BrowserRawInputModifiers, NSEvent.ModifierFlags, String)] = [
                (.control, .control, "Control"), (.alt, .option, "Alt"), (.shift, .shift, "Shift"), (.meta, .command, "Meta"),
            ]
            pressed = wrappers.filter { modifiers.contains($0.0) && !held.contains($0.1) }.compactMap {
                BrowserKeyboardEvent(rawKey: $0.2)
            }
        }
        for modifier in pressed {
            webView.replayBrowserKeyboardEvent(modifier, action: .keyDown)
        }
        let result = webView.replayBrowserKeyboardEvent(event, action: action)
        for modifier in pressed.reversed() {
            webView.replayBrowserKeyboardEvent(modifier, action: .keyUp)
        }
        guard case .delivered = result else { throw BrowserRawInputFailure.eventCreationFailed }
    }

    @MainActor
    private static func modifierFlags(_ modifiers: BrowserRawInputModifiers, webView: CmuxWebView) -> NSEvent.ModifierFlags {
        var flags = webView.browserNativeInputDeliveryOwner.activeModifierFlags
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.meta) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
