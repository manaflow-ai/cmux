import CmuxBrowser
import Foundation
import WebKit

/// `browser.input_mouse` and `browser.input_keyboard` on WebKit panels,
/// delivered through ``BrowserPanel/deliverNativeInput(_:to:)``.
extension TerminalController {
    nonisolated func v2BrowserInputMouse(params: [String: Any]) -> V2CallResult {
        v2BrowserRawInput(params: params, isMouse: true)
    }

    nonisolated func v2BrowserInputKeyboard(params: [String: Any]) -> V2CallResult {
        v2BrowserRawInput(params: params, isMouse: false)
    }

    private nonisolated func v2BrowserRawInput(params: [String: Any], isMouse: Bool) -> V2CallResult {
        let request: BrowserRawInputRequest
        do {
            request = isMouse
                ? try BrowserRawInputRequest(mouseParams: params)
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
        return v2BrowserWithPanelContext(params: params) { context in
            let panel = context.browserPanel
            let webView = context.webView
            var deliveryTask: Task<Void, Never>?
            let outcome: Result<CGPoint, BrowserRawInputFailure>? = v2AwaitCallback(timeout: 10) { finish in
                deliveryTask = Task { @MainActor in
                    do {
                        let position = try await panel.deliverNativeInput(steps, to: webView)
                        finish(.success(position))
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
        case .notWebKit:
            return .err(
                code: "not_supported",
                message: String(
                    localized: "cli.browser.rawInput.engineUnsupported",
                    defaultValue: "Raw input is not available for this browser engine yet"
                ),
                data: v2BrowserPanelFields(context)
            )
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

}
