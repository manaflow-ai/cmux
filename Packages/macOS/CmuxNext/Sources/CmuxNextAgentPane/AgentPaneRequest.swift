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
    case openTab(AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true)
    /// The command typed after `!` so far, whole each time, while the
    /// terminal that replaces the page is being made (`tab.typeAhead`).
    case typeAhead(String)
    /// Shell mode (`!` first in the composer or the new tab field): run
    /// `command` in `cwd` (``AgentPaneShell``); answers `{id}`. Only with a
    /// real gesture in the pane.
    case shellRun(command: String, cwd: String?)
    /// `shell.read {id, after}`: the run's output from byte `after`.
    case shellRead(id: String, after: Int)
    /// `shell.stop {id}`: interrupt the run's process group.
    case shellStop(id: String)
    /// `shell.complete {line, cwd}`: Tab in shell mode. `line` is the text before the caret; the
    /// user's own shell lists the candidates (``AgentPaneShellCompletion``). Only with a real
    /// gesture in the pane: completion functions run code.
    case shellComplete(line: String, cwd: String?)
    /// The agent picked on the new tab screen, to remember for the next
    /// new tab (`newTab.remember`).
    case rememberNewTab(agent: String)
    /// The new tab page got its first user input (`newTab.touched`); a
    /// touched page is never recycled into the prewarm pool.
    case touched
    /// The identified New Tab field mounted and took DOM focus.
    case newTabInputReady(String)
    /// The location bar picked an open tab or workspace: go there.
    case jump(AgentPaneJumpTarget, id: String)
    /// The new tab page asked to change a kind's New shortcut.
    case editShortcut(AgentPaneTabKind)
    /// The new tab page's "default: X" toggle: what Cmd-T opens
    /// (`tabs.newTabKind`; the App checks the value).
    case setDefaultKind(String)
    /// The new tab page asked the app to run a user facing action.
    case runAction(String)
    /// The new-tab project picker asked for the explicit Browse… fallback.
    case browseProject
    /// "Choose Folder…" (`workspace.chooseFolder`): the native folder sheet that sets the
    /// workspace's agent folder, after a real gesture (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    case chooseFolder
    /// Returns bounded recent project paths for the new-tab picker.
    case listProjects(String?)
    /// The empty-chat action opens the existing onboarding project/history import flow.
    case importAndSync
    /// The new-tab omnibar invoked a host-owned action id.
    case appAction(String)
    /// The chat header's tools and "..." menu: run app action `id` (one of
    /// ``AgentPaneModel/headerActions``) on this chat's tab, a split in `cwd`
    /// when given.
    case paneAction(String, cwd: String? = nil)
    /// The chat tab's state the header's menu labels read: `{pinned}`.
    case tabState
    /// The page reports whether repository checkpoint actions are available so
    /// native palette actions can stay capability-gated with the pane.
    case checkpointAvailability(Bool)
    /// `pane.painted`: the document drew its first frame after the handshake
    /// (once per document).
    case painted
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
    /// Reads the selected local session's GitHub `origin` for Markdown reference links.
    case githubRepository(cwd: String)
    /// `turn.undo`: the edited-files card's host revert (AgentPaneTurnUndo.swift).
    case turnUndo(AgentPaneTurnUndo)
    /// `turn.undo` whose params break its contract; nothing is read or written.
    case invalidTurnUndo
    /// `transport.open`: open the host's acpmux socket named by the last handshake
    /// (``AgentPaneTransport``); answers `{connection}` once it is open.
    case transportOpen
    /// `transport.send` with `{connection, frames}`: page frames for the host's socket, checked
    /// against ``AcpmuxPaneMethods``.
    case transportSend(connection: Int, frames: [String])
    /// `transport.close` with `{connection}`.
    case transportClose(connection: Int)
    /// `transport.gesture {intent}`: reserve the user's current gesture for one pick sent later (a
    /// pick held behind a harness switch); answers `{ticket}`. Nil intent: the params break the
    /// contract (``AgentPaneGestureIntent``).
    case transportGesture(AgentPaneGestureIntent?)
    /// `transport.gesture.release`: drop every ticket (the page's harness switch ended or failed).
    case transportGestureRelease
    /// What a reply links to: chips, images, the preview card's browsers (``AgentPaneReplyRequest``).
    case reply(AgentPaneReplyRequest)
    /// The ACP inspector's export (JSON Lines, at most
    /// ``maximumLogBytes`` UTF-8 bytes) to save where the user picks, under
    /// `suggestedName` (a plain file name ending in `.jsonl`).
    case saveLog(text: String, suggestedName: String)
    case unsupported(String)

    /// Most frames in one `transport.send` (the page sends what one task wrote).
    public static let maximumSendFrames = 4096

    /// A shell mode request: a command can carry secrets and `shell.read` polls, so never logged.
    public var isShell: Bool {
        switch self {
        case .shellRun, .shellRead, .shellStop, .shellComplete: true
        default: false
        }
    }

    /// A transport request: frequent and carrying chat content, so never logged with its values.
    public var isTransport: Bool {
        switch self {
        case .transportOpen, .transportSend, .transportClose, .transportGesture, .transportGestureRelease: true
        default: false
        }
    }

    public static let maximumPacingFrames = 640
    /// Longest `tab.open` text kept; a command or address is far shorter.
    public static let maximumOpenTabText = 8192

    /// The page keeps about 2M characters of wire log; JSON escaping and
    /// multi-byte text can grow that, but not past this.
    public static let maximumLogBytes = 16 * 1024 * 1024

    /// The save panel's name when the page sends none or an unusable one.
    public static let defaultLogName = "acp.jsonl"

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

    public static let handlerName = "agentSession"

    /// A shell run's id as ``AgentPaneShell`` mints them.
    static func shellID(_ params: [String: Any]?) -> String? {
        guard let id = params?["id"] as? String, !id.isEmpty, id.utf8.count <= 64 else { return nil }
        return id
    }

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
        case "pane.saveLog":
            if let text = params?["text"] as? String, !text.isEmpty, text.utf8.count <= Self.maximumLogBytes {
                self = .saveLog(text: text, suggestedName: Self.logFileName(params?["suggestedName"] as? String))
            } else {
                self = .unsupported(method)
            }
        case "pane.painted":
            self = .painted
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
                self = .openTab(kind, text: String(text.prefix(Self.maximumOpenTabText)), cwd: kind == .terminal ? cwd : nil,
                                search: kind == .browser && params?["search"] as? Bool == true,
                                run: kind != .terminal || params?["run"] as? Bool != false)
            } else {
                self = .unsupported(method)
            }
        case "tab.typeAhead":
            if let text = params?["text"] as? String {
                self = .typeAhead(String(text.prefix(Self.maximumOpenTabText)))
            } else {
                self = .unsupported(method)
            }
        case "shell.run":
            if let command = params?["command"] as? String,
               !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               command.utf8.count <= Self.maximumOpenTabText {
                // A relative folder would resolve against the app's, not the chat's.
                let cwd = (params?["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4096 ? $0 : nil }
                self = .shellRun(command: command, cwd: cwd)
            } else {
                self = .unsupported(method)
            }
        case "shell.read":
            if let id = Self.shellID(params), let after = (params?["after"] as? NSNumber)?.intValue, after >= 0 {
                self = .shellRead(id: id, after: after)
            } else {
                self = .unsupported(method)
            }
        case "shell.complete":
            if let line = params?["line"] as? String, line.utf8.count <= AgentPaneShellCompletion.maximumLine {
                let cwd = (params?["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4096 ? $0 : nil }
                self = .shellComplete(line: line, cwd: cwd)
            } else {
                self = .unsupported(method)
            }
        case "shell.stop":
            if let id = Self.shellID(params) { self = .shellStop(id: id) } else { self = .unsupported(method) }
        case "newTab.inputReady":
            if let token = params?["token"] as? String, !token.isEmpty, token.count <= 128 { self = .newTabInputReady(token) }
            else { self = .unsupported(method) }
        case "newTab.touched":
            self = .touched
        case "newTab.remember":
            // One input (R86): only the agent pick is remembered.
            if let agent = params?["agent"] as? String, !agent.isEmpty, agent.count <= 128 {
                self = .rememberNewTab(agent: agent)
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
        case "project.browse": self = .browseProject
        case "workspace.chooseFolder": self = .chooseFolder
        case "project.list":
            let query = (params?["query"] as? String).map { String($0.prefix(512)) }
            self = .listProjects(query)
        case "onboarding.importAndSync": self = .importAndSync
        case "app.action":
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128 { self = .appAction(id) }
            else { self = .unsupported(method) }
        case "pane.action":
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128 {
                let cwd = (params?["cwd"] as? String).flatMap { $0.hasPrefix("/") ? String($0.prefix(Self.maximumOpenTabText)) : nil }
                self = .paneAction(id, cwd: cwd)
            } else {
                self = .unsupported(method)
            }
        case "pane.tabState": self = .tabState
        case "shortcut.edit":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneTabKind.init(rawValue:)) {
                self = .editShortcut(kind)
            } else {
                self = .unsupported(method)
            }
        case "action.run":
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128 {
                self = .runAction(id)
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
        case "turn.undo": self = AgentPaneTurnUndo(params: params).map(AgentPaneRequest.turnUndo) ?? .invalidTurnUndo
        case "git.githubRepository":
            if let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") {
                self = .githubRepository(cwd: cwd)
            } else {
                self = .invalidGit(method)
            }
        case "git.diff", "git.status", "file.search", "git.checkpoint.diff":
            if let git = AgentPaneGitRequest(method: method, params: params) {
                self = .git(git)
            } else {
                self = .invalidGit(method)
            }
        case "transport.open": self = .transportOpen
        case "transport.gesture": self = .transportGesture(AgentPaneGestureIntent(gestureParams: params))
        case "transport.gesture.release": self = .transportGestureRelease
        case "transport.send":
            if let connection = params?["connection"] as? Int, let frames = params?["frames"] as? [String],
               !frames.isEmpty, frames.count <= Self.maximumSendFrames {
                self = .transportSend(connection: connection, frames: frames)
            } else {
                self = .unsupported(method)
            }
        case "transport.close":
            if let connection = params?["connection"] as? Int {
                self = .transportClose(connection: connection)
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
        case _ where AgentPaneReplyRequest.methods.contains(method):
            self = AgentPaneReplyRequest(method: method, params: params).map(AgentPaneRequest.reply) ?? .unsupported(method)
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
    /// out so the page sees `undefined`, as the TypeScript type expects. The
    /// Codable DTO is encoded once at the bridge boundary; NewTab projection
    /// and presentation limits belong to the web page.
    public static func handshake(_ handshake: AgentPaneHandshake) -> [String: Any] {
        var value = encodedObject(handshake)
        value["handoffStrings"] = AgentPaneHandoffStrings().values
        value["checkpointStrings"] = AgentPaneCheckpointStrings().values
        return success(value)
    }

    private static func encodedObject<Value: Encodable>(_ value: Value) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            assertionFailure("Agent pane bridge value must be JSON-compatible")
            return [:]
        }
        return dictionary
    }
}
/// What the location bar can jump to (`tab.jump`).
public nonisolated enum AgentPaneJumpTarget: String, Sendable {
    case tab, workspace
}
