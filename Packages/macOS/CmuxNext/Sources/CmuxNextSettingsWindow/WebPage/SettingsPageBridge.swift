import CmuxNextSettings
import Foundation
import WebKit

/// The page's requests (`window.webkit.messageHandlers.cmuxSettings`). Only
/// main-frame messages from `cmux-settings://page` are answered. Operations
/// named `settings.*` go to the backend unchanged; anything else that is not
/// a page operation (`ready`, `preview`, `preview.end`, `native.open`,
/// `sound.play`) is refused here, so the page can reach nothing but settings.
@MainActor
final class SettingsPageBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "cmuxSettings"

    /// Page operations the host answers (`ready`, `native.open`, ...).
    var pageOperation: ((_ operation: String, _ params: JSONValue) async -> JSONValue)?
    private let backend: any SettingsPageBackend

    init(backend: any SettingsPageBackend) {
        self.backend = backend
    }

    static let pageOperations: Set<String> = ["ready", "preview", "preview.end", "native.open", "sound.play"]

    /// Whether a message comes from the page itself.
    nonisolated static func isTrusted(frameIsMain: Bool, origin: WKSecurityOrigin) -> Bool {
        frameIsMain && origin.protocol == SettingsPageSchemeHandler.scheme && origin.host == SettingsPageSchemeHandler.host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard Self.isTrusted(frameIsMain: message.frameInfo.isMainFrame, origin: message.frameInfo.securityOrigin) else {
            return (nil, "untrusted frame")
        }
        let body = Self.json(message.body)
        guard let operation = body["op"]?.stringValue else { return (nil, "missing op") }
        let params = body["params"] ?? .object([:])
        let reply = await handle(operation, params: params)
        return (reply.foundationObject, nil)
    }

    /// Routes one request; the reply is the result or `{error: ...}`.
    func handle(_ operation: String, params: JSONValue) async -> JSONValue {
        if operation.hasPrefix("settings.") {
            do {
                return try await backend.request(operation, params: params)
            } catch let error as SettingsPageError {
                return error.reply
            } catch {
                return SettingsPageError(code: "unavailable", message: String(describing: error)).reply
            }
        }
        guard Self.pageOperations.contains(operation), let pageOperation else {
            return SettingsPageError(code: "invalid_params", message: "\(operation) is not a settings page operation").reply
        }
        return await pageOperation(operation, params)
    }

    static func json(_ body: Any) -> JSONValue {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let value = try? JSONValue.parse(data) else { return .object([:]) }
        return value
    }
}
