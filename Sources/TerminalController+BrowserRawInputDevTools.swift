import CoreGraphics
import CmuxBrowser
import Foundation

/// Sends raw browser input to Chromium through its trusted DevTools input
/// domain. The WebKit path remains native AppKit replay in
/// ``TerminalController+BrowserRawInput``.
extension TerminalController {
    @MainActor private static var v2DevToolsPointerBySurface: [UUID: CGPoint] = [:]

    nonisolated func v2BrowserRawInputOverDevTools(
        _ steps: [BrowserRawInputStep],
        page: any BrowserPage,
        context: V2BrowserPanelContext
    ) -> V2CallResult {
        let surfaceId = context.surfaceId
        var deliveryTask: Task<Void, Never>?
        let outcome: Result<CGPoint, any Error>? = v2AwaitCallback(timeout: 10) { finish in
            deliveryTask = Task { @MainActor in
                var pointer = Self.v2DevToolsPointerBySurface[surfaceId] ?? .zero
                do {
                    for step in steps {
                        let (method, params) = Self.v2DevToolsInputCommand(for: step, pointer: &pointer)
                        let body = try JSONSerialization.data(withJSONObject: params)
                        _ = try await page.sendDevToolsProtocolMessage(method: method, params: body)
                    }
                    Self.v2DevToolsPointerBySurface[surfaceId] = pointer
                    context.browserPanel.browserRawInputPointer.position = pointer
                    finish(.success(pointer))
                } catch {
                    Self.v2DevToolsPointerBySurface[surfaceId] = pointer
                    finish(.failure(error))
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
        case .failure(let error):
            if case .unavailable(_, let reason)? = error as? BrowserEngineError {
                return .err(
                    code: "engine_unavailable",
                    message: error.localizedDescription,
                    data: v2BrowserPanelFields(context, adding: ["reason": reason.code])
                )
            }
            return .err(
                code: "internal_error",
                message: String(describing: error),
                data: v2BrowserPanelFields(context)
            )
        case .success(let position):
            return .ok(v2BrowserPanelFields(context, adding: [
                "steps": steps.count,
                "pointer": ["x": position.x, "y": position.y],
            ]))
        }
    }

    /// Maps one parsed input step to the corresponding DevTools command.
    nonisolated static func v2DevToolsInputCommand(
        for step: BrowserRawInputStep,
        pointer: inout CGPoint
    ) -> (method: String, params: [String: Any]) {
        func mouse(
            _ type: String,
            _ point: CGPoint,
            button: String,
            clickCount: Int,
            modifiers: BrowserRawInputModifiers,
            extra: [String: Any] = [:]
        ) -> (String, [String: Any]) {
            pointer = point
            var params: [String: Any] = [
                "type": type,
                "x": point.x,
                "y": point.y,
                "button": button,
                "clickCount": clickCount,
                "modifiers": modifiers.rawValue,
            ]
            params.merge(extra) { _, new in new }
            return ("Input.dispatchMouseEvent", params)
        }

        switch step {
        case .mouseMoved(let point, let modifiers):
            return mouse("mouseMoved", point, button: "none", clickCount: 0, modifiers: modifiers)
        case .mousePressed(let point, let button, let clickCount, let modifiers):
            return mouse("mousePressed", point, button: button.rawValue, clickCount: clickCount, modifiers: modifiers)
        case .mouseReleased(let point, let button, let clickCount, let modifiers):
            return mouse("mouseReleased", point, button: button.rawValue, clickCount: clickCount, modifiers: modifiers)
        case .mouseWheel(let point, let deltaX, let deltaY, let modifiers):
            return mouse(
                "mouseWheel", point, button: "none", clickCount: 0, modifiers: modifiers,
                extra: ["deltaX": deltaX, "deltaY": deltaY]
            )
        case .keyDown(let key, let modifiers):
            return ("Input.dispatchKeyEvent", v2DevToolsKeyParams(key, down: true, modifiers: modifiers))
        case .keyUp(let key, let modifiers):
            return ("Input.dispatchKeyEvent", v2DevToolsKeyParams(key, down: false, modifiers: modifiers))
        case .insertText(let text):
            return ("Input.insertText", ["text": text])
        }
    }

    /// Builds a trusted Chromium key event, preserving printable text only for
    /// unmodified key-downs.
    nonisolated static func v2DevToolsKeyParams(
        _ rawKey: String,
        down: Bool,
        modifiers: BrowserRawInputModifiers
    ) -> [String: Any] {
        let event = BrowserKeyboardEvent(rawKey: rawKey)
        let key = event?.key ?? rawKey
        var params: [String: Any] = [
            "key": key,
            "code": event?.code ?? rawKey,
            "windowsVirtualKeyCode": event?.legacyKeyCode ?? 0,
            "modifiers": modifiers.rawValue,
        ]
        if let keyCode = event?.nativeKey?.keyCode {
            params["nativeVirtualKeyCode"] = Int(keyCode)
        }
        guard down else {
            params["type"] = "keyUp"
            return params
        }
        let typing = modifiers.intersection([.control, .meta]).isEmpty
        let text: String?
        if key == "Enter" {
            text = "\r"
        } else if key.count == 1,
                  let scalar = key.unicodeScalars.first,
                  scalar.value >= 0x20,
                  scalar.value != 0x7F {
            text = key
        } else {
            text = nil
        }
        if typing, let text {
            params["type"] = "keyDown"
            params["text"] = text
            params["unmodifiedText"] = text
        } else {
            params["type"] = "rawKeyDown"
        }
        return params
    }
}
