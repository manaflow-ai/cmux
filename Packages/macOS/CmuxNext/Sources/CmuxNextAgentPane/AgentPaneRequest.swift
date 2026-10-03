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
    /// most ``maximumPacingFrames``; returns the native display interval and rate mode.
    case framePacing([Double])
    /// Applies the page's adaptive rate decision; fixed-rate panes ignore it.
    case renderRate(Bool)
    /// The new tab page chose a terminal or browser: replace the tab with
    /// one, running or opening `text` (a command, a URL or a search), a
    /// terminal in `cwd` when the page picked a folder.
    case openTab(AgentPaneTabKind, text: String, cwd: String? = nil)
    /// The location bar picked an open tab or workspace: go there.
    case jump(AgentPaneJumpTarget, id: String)
    /// The new tab page asked to change a kind's New shortcut.
    case editShortcut(AgentPaneTabKind)
    /// The new tab page's "default: X" toggle: what Cmd-T opens
    /// (`tabs.newTabKind`; the App checks the value).
    case setDefaultKind(String)
    /// The page reports whether repository checkpoint actions are available so
    /// native palette actions can stay capability-gated with the pane.
    case checkpointAvailability(Bool)
    /// The composer's mic: `dictation.toggle`, `.start`, `.stop`, `.cancel`,
    /// or `dictation.openSettings` with `{permission}`.
    case dictation(AgentPaneDictationCommand)
    /// `file.open` with `{path, where}`: a changed file from the changes view,
    /// in a tab beside the agent or in the text editor.
    case openFile(path: String, target: AgentPaneFileTarget)
    /// `browser.open` with `{url}`: a turn's local web page (its preview
    /// card), in a browser tab of the pane. Only loopback http(s) pages
    /// (`URL.isAgentPanePreview`); anything else is unsupported.
    case openPreview(URL)
    /// The quick panel's page: Esc hides the panel, keeping its draft.
    case quickDismiss
    /// The quick panel's page: open its chat in the main window and hide
    /// the panel. `{sessionId}` is optional; without it the host uses the
    /// session the page last persisted.
    case quickOpenInWindow(sessionId: String?)
    /// `git.diff` or `git.status` with `{cwd, …}`: the changes view's reads of
    /// the session's repository, which the App runs on the session host.
    case git(AgentPaneGitRequest)
    /// `git.diff` or `git.status` whose params the bridge refused (no
    /// absolute `cwd`, an unknown scope); answered `native.invalid_request`.
    case invalidGit(String)
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
        case "pane.renderRate":
            if let full = params?["full"] as? Bool {
                self = .renderRate(full)
            } else {
                self = .unsupported(method)
            }
        case "tab.open":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneTabKind.init(rawValue:)), kind != .agent {
                let text = params?["text"] as? String ?? ""
                let cwd = (params?["cwd"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumOpenTabText)) }
                self = .openTab(kind, text: String(text.prefix(Self.maximumOpenTabText)), cwd: kind == .terminal ? cwd : nil)
            } else {
                self = .unsupported(method)
            }
        case "tab.jump":
            if let target = (params?["target"] as? String).flatMap(AgentPaneJumpTarget.init(rawValue:)),
               let id = params?["id"] as? String, !id.isEmpty, id.count <= 256 {
                self = .jump(target, id: id)
            } else {
                self = .unsupported(method)
            }
        case "tab.setDefaultKind":
            if let kind = params?["kind"] as? String, !kind.isEmpty, kind.count <= 32 {
                self = .setDefaultKind(kind)
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
        case "browser.open":
            if let text = params?["url"] as? String, text.count <= Self.maximumOpenTabText,
               let url = URL(string: text), url.isAgentPanePreview {
                self = .openPreview(url)
            } else {
                self = .unsupported(method)
            }
        case "quick.dismiss": self = .quickDismiss
        case "quick.openInWindow":
            let id = params?["sessionId"] as? String
            self = .quickOpenInWindow(sessionId: id?.isEmpty == false ? id : nil)
        case "git.diff", "git.status", "file.search":
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
        if let newTab = handshake.newTab { value["newTab"] = newTab.reply }
        if let cwd = handshake.cwd { value["cwd"] = cwd }
        if let draft = handshake.draft { value["draft"] = draft }
        if let prompt = handshake.prompt { value["prompt"] = prompt }
        if let adopt = handshake.adopt { value["adopt"] = adopt.reply }
        if let surface = handshake.surface { value["surface"] = surface.rawValue }
        if let linkScheme = handshake.linkScheme { value["linkScheme"] = linkScheme }
        if let sessionMustExist = handshake.sessionMustExist { value["sessionMustExist"] = sessionMustExist }
        if let revealTurn = handshake.revealTurn { value["revealTurn"] = revealTurn }
        value["handoffStrings"] = AgentPaneHandoffStrings().values
        value["checkpointStrings"] = AgentPaneCheckpointStrings().values
        return success(value)
    }
}

/// What the location bar can jump to (`tab.jump`).
public nonisolated enum AgentPaneJumpTarget: String, Sendable {
    case tab, workspace
}
