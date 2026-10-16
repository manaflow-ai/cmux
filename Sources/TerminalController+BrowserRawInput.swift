import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// Where `browser.input_mouse` left the pointer in one browser panel, so
/// `down`, `up` and `wheel` act at the last `move`.
@MainActor
final class BrowserRawInputPointerState {
    var position: CGPoint = .zero
    var pressedButton: BrowserReplMouseButton?
}

/// Why a raw input request failed after it was read.
private enum BrowserRawInputFailure: Error, Sendable {
    case stale
    case timedOut
    case notRenderable
    case dragUnsupported
    case unknownKey(String)
    case eventCreationFailed
}

/// `browser.input_mouse` and `browser.input_keyboard` on WebKit panels.
///
/// Each step becomes a native AppKit event delivered straight to WebKit (the
/// same path as the browser REPL), so the page sees trusted DOM events. Input
/// never focuses the window or moves the real cursor. A hidden pane renders
/// in an offscreen host for the duration of the request.
extension TerminalController {
    nonisolated func v2BrowserInputMouse(params: [String: Any]) -> V2CallResult {
        v2BrowserRawInput(params: params, isMouse: true)
    }

    nonisolated func v2BrowserInputKeyboard(params: [String: Any]) -> V2CallResult {
        v2BrowserRawInput(params: params, isMouse: false)
    }

    private nonisolated func v2BrowserRawInput(params: [String: Any], isMouse: Bool) -> V2CallResult {
        v2BrowserWithPanelContext(params: params) { context in
            let panel = context.browserPanel
            let webView = context.webView
            let pointer = v2MainSync { panel.browserRawInputPointer.position }
            let request: BrowserRawInputRequest
            do {
                request = isMouse
                    ? try BrowserRawInputRequest(mouseParams: params, pointer: pointer)
                    : try BrowserRawInputRequest(keyboardParams: params)
            } catch {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.browser.rawInput.invalid",
                        defaultValue: "The input request is not valid"
                    ),
                    data: ["reason": String(describing: error)]
                )
            }
            let steps = request.steps
            if let enginePage = v2MainSync({ panel.automationEnginePage }),
               v2MainSync({ enginePage.capabilities.contains(.devToolsProtocol) }) {
                return v2BrowserRawInputOverDevTools(steps, page: enginePage, context: context)
            }
            var deliveryTask: Task<Void, Never>?
            let outcome: Result<CGPoint, BrowserRawInputFailure>? = v2AwaitCallback(timeout: 10) { finish in
                deliveryTask = Task { @MainActor in
                    do {
                        finish(.success(try await Self.deliverRawInput(steps, panel: panel, webView: webView)))
                    } catch let failure as BrowserRawInputFailure {
                        finish(.failure(failure))
                    } catch {
                        finish(.failure(.eventCreationFailed))
                    }
                }
            }
            switch outcome {
            case nil:
                deliveryTask?.cancel()
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.browser.rawInput.timeout",
                        defaultValue: "Timed out delivering browser input"
                    ),
                    data: v2BrowserPanelFields(context)
                )
            case .success(let position):
                return .ok(v2BrowserPanelFields(context, adding: [
                    "steps": steps.count,
                    "pointer": ["x": position.x, "y": position.y],
                ]))
            case .failure(let failure):
                return v2BrowserRawInputError(failure, context: context)
            }
        }
    }

    private nonisolated func v2BrowserRawInputError(
        _ failure: BrowserRawInputFailure,
        context: V2BrowserPanelContext
    ) -> V2CallResult {
        switch failure {
        case .stale:
            return .err(
                code: "stale_state",
                message: String(
                    localized: "browser.automation.error.superseded",
                    defaultValue: "The browser surface was already recovered. Retry the command."
                ),
                data: v2BrowserPanelFields(context)
            )
        case .timedOut:
            return .err(
                code: "timeout",
                message: String(
                    localized: "browser.automation.error.documentReadinessTimedOut",
                    defaultValue: "Timed out waiting for the browser document to become ready"
                ),
                data: v2BrowserPanelFields(context)
            )
        case .notRenderable:
            return .err(
                code: "unavailable",
                message: String(
                    localized: "cli.browser.rawInput.notRenderable",
                    defaultValue: "This browser pane cannot take native input right now"
                ),
                data: v2BrowserPanelFields(context)
            )
        case .dragUnsupported:
            return .err(
                code: "not_supported",
                message: String(
                    localized: "cli.browser.rawInput.dragUnsupported",
                    defaultValue: "Moving with a button held (a drag) is not supported here; use cmux browser repl"
                ),
                data: v2BrowserPanelFields(context)
            )
        case .unknownKey(let key):
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.rawInput.unknownKey",
                    defaultValue: "The browser has no native key for this value"
                ),
                data: v2BrowserPanelFields(context, adding: ["key": key])
            )
        case .eventCreationFailed:
            return .err(
                code: "internal_error",
                message: String(
                    localized: "cli.browser.error.operationFailed",
                    defaultValue: "Browser operation failed"
                ),
                data: v2BrowserPanelFields(context)
            )
        }
    }

    /// Delivers `steps` to the panel's web view and returns where the
    /// pointer ends.
    @MainActor
    private static func deliverRawInput(
        _ steps: [BrowserRawInputStep],
        panel: BrowserPanel,
        webView: WKWebView
    ) async throws -> CGPoint {
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
        let needsWindow = steps.contains { step in
            switch step {
            case .mouseMoved, .mousePressed, .mouseReleased, .mouseWheel: true
            case .keyDown, .keyUp, .insertText: false
            }
        }
        let deliver: @MainActor (NSWindow?) async throws -> Void = { window in
            for step in steps {
                try Task.checkCancellation()
                try await deliverRawInputStep(step, webView: cmuxWebView, window: window, state: state)
            }
        }
        if !needsWindow {
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
        case .mouseMoved(let point, let modifiers):
            // A move with a button held would let WebKit start a system drag
            // session; only the REPL arms the drag capture that contains it.
            guard state.pressedButton == nil else { throw BrowserRawInputFailure.dragUnsupported }
            state.position = point
            try sendMouse(.mouseMoved, button: .left, at: point, clickCount: 0, modifiers: modifiers, webView: webView, window: window)
        case .mousePressed(let point, let button, let clickCount, let modifiers):
            state.position = point
            let type: NSEvent.EventType = switch button {
            case .left: .leftMouseDown
            case .right: .rightMouseDown
            case .middle: .otherMouseDown
            }
            try sendMouse(type, button: button, at: point, clickCount: clickCount, modifiers: modifiers, webView: webView, window: window)
            state.pressedButton = button
        case .mouseReleased(let point, let button, let clickCount, let modifiers):
            state.position = point
            let type: NSEvent.EventType = switch button {
            case .left: .leftMouseUp
            case .right: .rightMouseUp
            case .middle: .otherMouseUp
            }
            try sendMouse(type, button: button, at: point, clickCount: clickCount, modifiers: modifiers, webView: webView, window: window)
            state.pressedButton = nil
        case .mouseWheel(let point, let deltaX, let deltaY, let modifiers):
            guard let window,
                  let event = BrowserReplNativeInput.wheelEvent(
                    webView: webView,
                    window: window,
                    cssPoint: point,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    modifierFlags: modifierFlags(modifiers, webView: webView)
                  ) else {
                throw BrowserRawInputFailure.eventCreationFailed
            }
            state.position = point
            webView.deliverAutomationMouseEvent(event)
            await BrowserReplNativeInput.roundTrip(webView)
            return
        case .keyDown(let key, let modifiers):
            try replayKey(key, action: .keyDown, modifiers: modifiers, webView: webView)
            return
        case .keyUp(let key, let modifiers):
            try replayKey(key, action: .keyUp, modifiers: modifiers, webView: webView)
            return
        case .insertText(let text):
            try await BrowserReplNativeInput.insertText(text, into: webView)
            return
        }
        await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
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
                modifierFlags: modifierFlags(modifiers, webView: webView)
              ) else {
            throw BrowserRawInputFailure.eventCreationFailed
        }
        webView.deliverAutomationMouseEvent(event)
    }

    /// Replays one key, wrapping it in the modifier keys `modifiers` names
    /// that are not already held, so the page sees them as a person would
    /// press them.
    @MainActor
    private static func replayKey(
        _ key: String,
        action: BrowserKeyboardAction,
        modifiers: BrowserRawInputModifiers,
        webView: CmuxWebView
    ) throws {
        guard let event = BrowserKeyboardEvent(rawKey: key), event.nativeKey != nil else {
            throw BrowserRawInputFailure.unknownKey(key)
        }
        let held = webView.browserNativeInputDeliveryOwner.activeModifierFlags
        let wrappers: [(BrowserRawInputModifiers, NSEvent.ModifierFlags, String)] = [
            (.control, .control, "Control"), (.alt, .option, "Alt"), (.shift, .shift, "Shift"), (.meta, .command, "Meta"),
        ]
        let pressed = wrappers.filter { modifiers.contains($0.0) && !held.contains($0.1) }.compactMap {
            BrowserKeyboardEvent(rawKey: $0.2)
        }
        for modifier in pressed {
            webView.replayBrowserKeyboardEvent(modifier, action: .keyDown)
        }
        let result = webView.replayBrowserKeyboardEvent(event, action: action)
        for modifier in pressed.reversed() {
            webView.replayBrowserKeyboardEvent(modifier, action: .keyUp)
        }
        guard result == .delivered else { throw BrowserRawInputFailure.eventCreationFailed }
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
