public import Foundation

/// A request the page posts to `window.webkit.messageHandlers.agentSession`:
/// `{id, method, params}`. Only host-owned methods reach Swift; chat actions
/// run in the page against acpmux.
public nonisolated enum AgentPaneRequest: Equatable, Sendable {
    /// The page loaded and wants the handshake.
    case ready
    /// The page switched to or created `sessionId`; the host keeps it so a
    /// reload or relaunch of the pane shows the same session.
    case persistSession(String)
    case unsupported(String)

    public static let handlerName = "agentSession"

    /// Decodes a `WKScriptMessage.body` (a dictionary once bridged).
    public init(body: Any) {
        guard let object = body as? [String: Any], let method = object["method"] as? String else {
            self = .unsupported("")
            return
        }
        let params = object["params"] as? [String: Any]
        switch method {
        case "ready":
            self = .ready
        case "chat.persistSession":
            if let id = params?["sessionId"] as? String, !id.isEmpty {
                self = .persistSession(id)
            } else {
                self = .unsupported(method)
            }
        default:
            self = .unsupported(method)
        }
    }
}

/// The page's reply envelope: `{ok: true, value}` or
/// `{ok: false, error: {code, userMessage}}`.
public nonisolated enum AgentPaneReply {
    /// JSON-compatible dictionaries for the `WKScriptMessageHandlerWithReply`
    /// reply handler, which bridges them to JavaScript objects.
    public static func success(_ value: Any = NSNull()) -> [String: Any] {
        ["ok": true, "value": value]
    }

    public static func failure(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "userMessage": message]]
    }

    /// The handshake as the dictionary the page receives. Nil fields are left
    /// out so the page sees `undefined`, as the TypeScript type expects.
    public static func handshake(_ handshake: AgentPaneHandshake) -> [String: Any] {
        var value: [String: Any] = [
            "protocolVersion": handshake.protocolVersion,
            "transport": handshake.transport.rawValue,
        ]
        if let endpoint = handshake.endpoint { value["endpoint"] = endpoint }
        if let token = handshake.token { value["token"] = token }
        if let sessionId = handshake.sessionId { value["sessionId"] = sessionId }
        if let newSession = handshake.newSession { value["newSession"] = newSession }
        return success(value)
    }
}
