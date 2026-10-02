public import Foundation

/// A request the page posts to `window.webkit.messageHandlers.agentSession`:
/// `{id, method, params}`. Only host-owned methods reach Swift; chat actions
/// run in the page against acpmux.
public nonisolated enum AgentPaneRequest: Equatable, Sendable {
    /// The page loaded and wants the handshake.
    case ready
    /// The page lost its daemon and wants a fresh handshake (a restarted
    /// daemon has a new port and token), without starting one.
    case reconnect
    /// The page switched to or created `sessionId`; the host keeps it so a
    /// reload or relaunch of the pane shows the same session.
    case persistSession(String)
    /// A settled transcript scroll's frame intervals in milliseconds, at
    /// most ``maximumPacingFrames``; the pane picks its rendering rate from them.
    case framePacing([Double])
    /// The ACP inspector's export (JSON Lines, at most
    /// ``maximumLogBytes`` UTF-8 bytes) to save where the user picks, under
    /// `suggestedName` (a plain file name ending in `.jsonl`).
    case saveLog(text: String, suggestedName: String)
    case unsupported(String)

    public static let maximumPacingFrames = 640

    /// The page keeps about 2M characters of wire log; JSON escaping and
    /// multi-byte text can grow that, but not past this.
    public static let maximumLogBytes = 16 * 1024 * 1024

    /// The save panel's name when the page sends none or an unusable one.
    public static let defaultLogName = "acp.jsonl"

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
            self = params?["reconnect"] as? Bool == true ? .reconnect : .ready
        case "chat.persistSession":
            if let id = params?["sessionId"] as? String, !id.isEmpty {
                self = .persistSession(id)
            } else {
                self = .unsupported(method)
            }
        case "pane.framePacing":
            if let intervals = params?["intervals"] as? [Double], !intervals.isEmpty {
                self = .framePacing(Array(intervals.prefix(Self.maximumPacingFrames)))
            } else {
                self = .unsupported(method)
            }
        case "pane.saveLog":
            if let text = params?["text"] as? String, !text.isEmpty, text.utf8.count <= Self.maximumLogBytes {
                self = .saveLog(text: text, suggestedName: Self.logFileName(params?["suggestedName"] as? String))
            } else {
                self = .unsupported(method)
            }
        default:
            self = .unsupported(method)
        }
    }

    /// `name` as a plain `.jsonl` file name: path separators and control
    /// characters removed, at most 120 characters, ``defaultLogName`` when
    /// nothing usable is left.
    static func logFileName(_ name: String?) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: (name ?? "").unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        var base = cleaned.hasSuffix(".jsonl") ? String(cleaned.dropLast(6)) : cleaned
        base = String(base.prefix(114))
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? defaultLogName : base + ".jsonl"
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
