import CmuxNextDictation
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
    /// The new tab page chose a terminal or browser: replace the tab with
    /// one, running or opening `text` (a command, a URL or a search).
    case openTab(AgentPaneTabKind, text: String)
    /// The new tab page asked to change a kind's New shortcut.
    case editShortcut(AgentPaneTabKind)
    /// The composer's mic: `dictation.toggle`, `.start`, `.stop`, `.cancel`,
    /// or `dictation.openSettings` with `{permission}`.
    case dictation(AgentPaneDictationCommand)
    /// `file.open` with `{path, where}`: a changed file from the changes view,
    /// in a tab beside the agent or in the text editor.
    case openFile(path: String, target: AgentPaneFileTarget)
    case unsupported(String)

    public static let maximumPacingFrames = 640
    /// Longest `tab.open` text kept; a command or address is far shorter.
    public static let maximumOpenTabText = 8192

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
        case "tab.open":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneTabKind.init(rawValue:)), kind != .agent {
                let text = params?["text"] as? String ?? ""
                self = .openTab(kind, text: String(text.prefix(Self.maximumOpenTabText)))
            } else {
                self = .unsupported(method)
            }
        case "shortcut.edit":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneTabKind.init(rawValue:)) {
                self = .editShortcut(kind)
            } else {
                self = .unsupported(method)
            }
        case "file.open":
            if let path = params?["path"] as? String, !path.isEmpty,
               let raw = params?["where"] as? String, let target = AgentPaneFileTarget(rawValue: raw) {
                self = .openFile(path: path, target: target)
            } else {
                self = .unsupported(method)
            }
        case "dictation.toggle": self = .dictation(.toggle)
        case "dictation.start": self = .dictation(.start)
        case "dictation.stop": self = .dictation(.stop)
        case "dictation.cancel": self = .dictation(.cancel)
        case "dictation.openSettings":
            if let raw = params?["permission"] as? String, let permission = DictationPermission(rawValue: raw) {
                self = .dictation(.openSettings(permission))
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
        if let newTab = handshake.newTab { value["newTab"] = newTab.reply }
        if let cwd = handshake.cwd { value["cwd"] = cwd }
        if let draft = handshake.draft { value["draft"] = draft }
        return success(value)
    }
}
