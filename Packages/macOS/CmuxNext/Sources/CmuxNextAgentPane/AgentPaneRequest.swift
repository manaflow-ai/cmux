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
    /// The page reports whether repository checkpoint actions are available so
    /// native palette actions can stay capability-gated with the pane.
    case checkpointAvailability(Bool)
    /// The composer's mic: `dictation.toggle`, `.start`, `.stop`, `.cancel`,
    /// or `dictation.openSettings` with `{permission}`.
    case dictation(AgentPaneDictationCommand)
    /// `file.open` with `{path, where}`: a changed file from the changes view,
    /// in a tab beside the agent or in the text editor.
    case openFile(path: String, target: AgentPaneFileTarget)
    /// `git.diff` or `git.status` with `{cwd, …}`: the changes view's reads of
    /// the session's repository, which the App runs on the session host.
    case git(AgentPaneGitRequest)
    /// `git.diff` or `git.status` whose params the bridge refused (no
    /// absolute `cwd`, an unknown scope); answered `native.invalid_request`.
    case invalidGit(String)
    case unsupported(String)

    public static let maximumPacingFrames = 640

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
        case "pane.checkpointAvailability":
            if let available = params?["available"] as? Bool {
                self = .checkpointAvailability(available)
            } else {
                self = .unsupported(method)
            }
        case "pane.framePacing":
            if let intervals = params?["intervals"] as? [Double], !intervals.isEmpty {
                self = .framePacing(Array(intervals.prefix(Self.maximumPacingFrames)))
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
        case "git.diff", "git.status":
            if let git = AgentPaneGitRequest(method: method, params: params) {
                self = .git(git)
            } else {
                self = .invalidGit(method)
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
/// `{ok: false, error: {code, userMessage, details?, retryable?, origin?}}`.
public nonisolated enum AgentPaneReply {
    /// JSON-compatible dictionaries for the `WKScriptMessageHandlerWithReply`
    /// reply handler, which bridges them to JavaScript objects.
    public static func success(_ value: Any = NSNull()) -> [String: Any] {
        ["ok": true, "value": value]
    }

    public static func failure(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "userMessage": message]]
    }

    /// A failure that says who failed (`origin`) and carries the session
    /// host's `details` (a JSON-compatible value) and `retryable`. Nil fields
    /// are left out so the page sees `undefined`.
    public static func failure(code: String, message: String, details: Any?, retryable: Bool?, origin: String) -> [String: Any] {
        var error: [String: Any] = ["code": code, "userMessage": message, "origin": origin]
        if let details { error["details"] = details }
        if let retryable { error["retryable"] = retryable }
        return ["ok": false, "error": error]
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
        if let cwd = handshake.cwd { value["cwd"] = cwd }
        if let draft = handshake.draft { value["draft"] = draft }
        if let prompt = handshake.prompt { value["prompt"] = prompt }
        value["handoffStrings"] = AgentPaneHandoffStrings().values
        value["checkpointStrings"] = AgentPaneCheckpointStrings().values
        return success(value)
    }
}
