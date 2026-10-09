import CmuxNextDictation
import Foundation

extension AgentPaneRequest {
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
        case "chat.readDraft":
            if let id = params?["sessionId"] as? String, !id.isEmpty {
                self = .readDraft(id)
            } else {
                self = .unsupported(method)
            }
        case "chat.writeDraft":
            if let id = params?["sessionId"] as? String, !id.isEmpty,
               let text = params?["text"] as? String {
                self = .writeDraft(id, text: String(text.prefix(Self.maximumDraftText)))
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
        case "pane.edit":
            if let command = (params?["command"] as? String).flatMap(AgentPaneEditCommand.init(rawValue:)) {
                self = .edit(command)
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
