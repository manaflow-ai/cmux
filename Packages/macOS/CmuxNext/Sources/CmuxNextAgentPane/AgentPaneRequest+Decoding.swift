import CmuxNextCloud
import CmuxNextDictation
import CmuxNextSettings
import Foundation

extension AgentPaneRequest {
    private nonisolated static let maximumUploadStageChunk = 512 * 1024

    /// A Cloud environment id as the platform makes them (`env_` and up to 64 letters, digits, `_`
    /// or `-`): the only `environment` `action.run` passes on.
    static func isCloudEnvironmentID(_ id: String) -> Bool {
        id.hasPrefix("env_") && (5...68).contains(id.count)
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// An editor id of cmux-window-rules' table (`vscode`, `rustrover`): 1 to 32 lowercase ASCII letters, digits or
    /// dashes, so it names a table row and carries nothing itself. The App opens only an installed table editor.
    static func isEditorID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// A page's one-time hand-off token (webviews commandPlace.ts: a UUID): 16 to 64 ASCII letters,
    /// digits and dashes, so it names a stored entry and carries nothing itself.
    static func isHandoffToken(_ token: String) -> Bool {
        (16...64).contains(token.count)
            && token.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// `action.run`'s `sessions`: Evacuate and Bring Back name 1...500 chats; a chat-list row's place pick, Cancel or
    /// Retry names exactly one, and never with `session` (the tab's own chat). Each id is usable and has no comma
    /// (the app's handlers read the list comma-joined).
    static func areSessionTargets(_ sessions: [String], id: String, alongside session: String?) -> Bool {
        let usable = sessions.allSatisfy { !$0.isEmpty && $0.count <= 256 && !$0.contains(",") }
        switch id {
        case "cloudEvacuate", "cloudBringBackAll": return usable && (1...500).contains(sessions.count)
        case "chatPlace.set", "chatPriority.set", "chatMove.cancel", "chatMove.retry": return usable && sessions.count == 1 && session == nil
        default: return false
        }
    }

    /// A GitHub repository's full name (webviews githubConnect.ts `isGitHubRepo`): an owner of 1 to 39
    /// letters, digits and inner dashes, a name of 1 to 100 letters, digits, `.`, `_` and `-`, never
    /// `.` or `..`. Connect GitHub passes only such a one on.
    static func isGitHubRepo(_ value: String) -> Bool {
        guard value.utf8.count <= 140,
              value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil else { return false }
        let name = value.split(separator: "/").last
        return name != "." && name != ".."
    }

    /// A GitHub account or org name: 1 to 39 letters, digits and inner dashes (webviews githubConnect.ts
    /// `isGitHubOwner`, acpmux `settings_ask`).
    static func isGitHubOwner(_ value: String) -> Bool {
        value.utf8.count <= 39 && value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    nonisolated static func uploadStage(_ method: String, _ params: [String: Any]?) -> AgentPaneRequest {
        guard let params else { return .unsupported(method) }
        switch method {
        case "chat.upload.begin":
            guard let name = params["name"] as? String, AgentPaneUpload.isFileName(name),
                  let size = (params["size"] as? NSNumber)?.intValue, size >= 0 else { return .unsupported(method) }
            let batchToken = params["batchToken"] as? String
            var batch: [AgentPaneUploadBatchEntry]?
            if let list = params["batch"] as? [[String: Any]] {
                guard !list.isEmpty else { return .unsupported(method) }
                let parsed = list.compactMap { item -> (String, Int)? in
                    guard let n = item["name"] as? String, AgentPaneUpload.isFileName(n), let s = (item["size"] as? NSNumber)?.intValue,
                          s >= 0 else { return nil }
                    return (n, s)
                }
                guard parsed.count == list.count else { return .unsupported(method) }
                batch = parsed.map { AgentPaneUploadBatchEntry(name: $0.0, size: $0.1) }
            }
            let begin = AgentPaneUploadStageRequest.begin(name: name, size: size, batchToken: batchToken, batch: batch)
            // A begin that names a Send (any of its three fields) goes only under that Send's ticket.
            guard ["sessionId", "promptId", "ticket"].contains(where: { params[$0] != nil }) else { return .uploadStage(begin) }
            guard let ticket = AgentPaneUploadSendTicket(beginParams: params) else { return .unsupported(method) }
            return .uploadStageForSend(begin, ticket)
        case "chat.upload.chunk":
            guard let token = params["token"] as? String, (1...128).contains(token.utf8.count),
                  let offset = (params["offset"] as? NSNumber)?.intValue, offset >= 0,
                  let text = params["data"] as? String,
                  // Its bytes are decoded where they are written, off the main thread (AgentPaneUploadWriter).
                  let data = AgentPaneUploadChunk(base64: text), data.count <= maximumUploadStageChunk else { return .unsupported(method) }
            return .uploadStage(.chunk(token: token, offset: offset, data: data))
        case "chat.upload.finish":
            guard let token = params["token"] as? String, (1...128).contains(token.utf8.count) else { return .unsupported(method) }
            return .uploadStage(.finish(token: token))
        case "chat.upload.cancel":
            guard let token = params["token"] as? String, (1...128).contains(token.utf8.count) else { return .unsupported(method) }
            return .uploadStage(.cancel(token: token))
        default: return .unsupported(method)
        }
    }

    /// `pane.action {id: "preview"}`: its `url` comes from transcript text, so only a local page
    /// (``Foundation/URL/isAgentPanePreview``) reaches the App.
    private static func preview(_ params: [String: Any]?, method: String) -> AgentPaneRequest {
        let toggle = params?["mode"] as? String == "toggle"
        guard let raw = params?["url"] else { return .preview(url: nil, toggle: toggle) }
        guard let text = raw as? String, text.count <= maximumOpenTabText, URL(string: text)?.isAgentPanePreview == true else {
            return .unsupported(method)
        }
        return .preview(url: text, toggle: toggle)
    }

    /// The chat folder a header action names: an absolute path, or one written from the home
    /// folder (`~/code/cmux`, as acpmux may record it), expanded (cx-awk8). Else none.
    private static func headerFolder(_ text: String) -> String? {
        guard !text.contains("\0") else { return nil }
        let path = text == "~" || text.hasPrefix("~/") ? NSHomeDirectory() + text.dropFirst() : text
        return path.hasPrefix("/") ? String(path.prefix(maximumOpenTabText)) : nil
    }

    /// Decodes a `WKScriptMessage.body` (a dictionary once bridged).
    public init(body: Any) {
        guard let object = body as? [String: Any], let method = object["method"] as? String else {
            self = .unsupported("")
            return
        }
        let params = object["params"] as? [String: Any]
        if method.hasPrefix("imessage.") {
            self = AgentPaneIMessageAction(rawValue: String(method.dropFirst("imessage.".count))).map(Self.imessage) ?? .unsupported(method)
            return
        }
        if AgentPaneCloudReservationRequest.methods.contains(method) {
            self = AgentPaneCloudReservationRequest(method: method, params: params).map(Self.cloudReservation) ?? .unsupported(method)
            return
        }
        if AgentPaneCloudEnvironmentRequest.methods.contains(method) {
            self = AgentPaneCloudEnvironmentRequest(method: method, params: params).map(Self.cloudEnvironment) ?? .unsupported(method)
            return
        }
        if AgentPaneCloudRepositoryRequest.methods.contains(method) {
            self = AgentPaneCloudRepositoryRequest(method: method, params: params).map(Self.cloudRepository) ?? .unsupported(method)
            return
        }
        if AgentPaneGitHubRequest.methods.contains(method) {
            self = AgentPaneGitHubRequest(method: method, params: params).map(Self.gitHub) ?? .unsupported(method)
            return
        }
        switch method {
        case "uiPointer.report":
            guard let params, JSONSerialization.isValidJSONObject(params),
                  let data = try? JSONSerialization.data(withJSONObject: params),
                  let text = String(data: data, encoding: .utf8) else { self = .unsupported(method); return }
            self = .uiPointerReport(text)
        case "ready":
            self = params?["reconnect"] as? Bool == true ? .reconnect : .ready
        case "chat.missing":
            if let session = params?["session"] as? String, !session.isEmpty {
                self = .missingChat(session: session, reason: params?["reason"] as? String ?? "unknown")
            } else {
                self = .unsupported(method)
            }
        case "chat.persistSession":
            if let id = params?["sessionId"] as? String, !id.isEmpty {
                self = .persistSession(id)
            } else {
                self = .unsupported(method)
            }
        case "chat.cloudStartQueue":
            if let text = params?["text"] as? String {
                self = .cloudStartQueue(text)
            } else {
                self = .unsupported(method)
            }
        case "chat.unsentDraft":
            if let text = params?["text"] as? String {
                self = .unsentDraft(text)
            } else {
                self = .unsupported(method)
            }
        case "chat.leftover":
            if let text = params?["text"] as? String {
                self = .newChatLeftover(text)
            } else {
                self = .unsupported(method)
            }
        case "chat.leftoverTaken":
            if let text = params?["text"] as? String {
                self = .newChatLeftoverTaken(text)
            } else {
                self = .unsupported(method)
            }
        case "pane.checkpointAvailability":
            if let available = params?["available"] as? Bool {
                self = .checkpointAvailability(available)
            } else {
                self = .unsupported(method)
            }
        case "pane.commandAvailability":
            if let commands = params?["commands"] as? [String] {
                self = .commandAvailability(commands)
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
            if let save = AgentPaneSave(text: params?["text"], suggestedName: params?["suggestedName"], kind: .log) {
                self = .saveFile(save)
            } else {
                self = .unsupported(method)
            }
        case "pane.finishSound":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneFinishSound.Kind.init(rawValue:)) {
                self = .finishSound(kind)
            } else {
                self = .unsupported(method)
            }
        case "pane.saveFile":
            // A document's kind only: the inspector's log has its own method.
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneSave.Kind.init(rawValue:)), kind != .log,
               let save = AgentPaneSave(text: params?["text"], suggestedName: params?["suggestedName"], kind: kind) {
                self = .saveFile(save)
            } else {
                self = .unsupported(method)
            }
        case "pane.showContextUsage", "pane.showDictation", "pane.setScrollToBottomOnSend":
            if let show = params?["show"] as? Bool {
                let path: [String]
                switch method {
                case "pane.showDictation": path = AgentPaneComposerSetting.showDictationPath
                case "pane.setScrollToBottomOnSend": path = AgentPaneComposerSetting.scrollToBottomOnSendPath
                default: path = AgentPaneComposerSetting.showContextUsagePath
                }
                self = .composerSetting(path: path, show: show)
            } else {
                self = .unsupported(method)
            }
        case "pane.setAttachmentView":
            // The composer's Inline, Strip or Inline and Strip choice; the page writes only this key with it.
            if let view = (params?["view"] as? String).flatMap(AgentPaneAttachmentView.init(rawValue:)) {
                self = .displaySetting(path: AgentPaneComposerSetting.attachmentViewPath, value: .string(view.rawValue))
            } else {
                self = .unsupported(method)
            }
        case "pane.setComposerRing":
            // The composer ring's Context or Plan Usage choice; the page writes only this key with it.
            if let ring = (params?["ring"] as? String).flatMap(AgentPaneComposerRing.init(rawValue:)) {
                self = .displaySetting(path: AgentPaneComposerSetting.composerRingPath, value: .string(ring.rawValue))
            } else {
                self = .unsupported(method)
            }
        case "pane.setDictationSource":
            // The mic menu's source pick; the page writes only this key with it.
            if let source = (params?["source"] as? String).flatMap(AgentPaneDictationSource.init(rawValue:)) {
                self = .displaySetting(path: AgentPaneComposerSetting.dictationSourcePath, value: .string(source.rawValue))
            } else {
                self = .unsupported(method)
            }
        case "pane.setRemoteControl":
            // Session Info's Remote Control switch: one Bool, nothing else.
            if let on = params?["on"] as? Bool, Set((params ?? [:]).keys) == ["on"] {
                self = .remoteControl(on: on)
            } else {
                self = .unsupported(method)
            }
        case "pane.noticeAction":
            // A native notice's button (AgentPaneNotice): its id, nothing else.
            if let id = params?["id"] as? String, Set((params ?? [:]).keys) == ["id"] {
                self = .paneNoticeAction(id: id)
            } else {
                self = .unsupported(method)
            }
        case "tips.state":
            // `{}` reads the records, `{id, state}` keeps one, `{claim, feature?}` asks to show a tip.
            if let tips = AgentPaneFeatureTipRequest(params) {
                self = .featureTips(tips)
            } else {
                self = .unsupported(method)
            }
        case "pane.setDisplay":
            // Only the chat's own look keys: the page can never write another setting.
            if let key = params?["key"] as? String, let path = AgentPaneDisplaySetting.writablePath(key) {
                let raw = params?["value"]
                let value = raw == nil || raw is NSNull ? nil : raw.flatMap(JSONValue.init(foundation:))
                if raw == nil || raw is NSNull || value != nil {
                    self = .displaySetting(path: path, value: value)
                } else {
                    self = .unsupported(method)
                }
            } else {
                self = .unsupported(method)
            }
        case "pane.clientReady":
            if let ready = params?["ready"] as? Bool {
                self = .clientReady(ready)
            } else {
                self = .unsupported(method)
            }
        case "pane.painted":
            self = .painted(fromKeptTail: params?["drewKeptTail"] as? Bool ?? false,
                            settled: params?["settled"] as? Bool ?? false,
                            copy: params?["copy"] as? Bool ?? false,
                            live: params?["live"] as? Bool ?? false)
        case "pane.inputEchoed":
            if let epochMs = params?["echoedEpochMs"] as? Double, epochMs.isFinite {
                self = .inputEchoed(at: Date(timeIntervalSince1970: epochMs / 1_000))
            } else {
                self = .unsupported(method)
            }
        case "pane.launchSettle":
            if let epochMs = params?["settledEpochMs"] as? Double, epochMs.isFinite,
               let px = params?["maxMovePx"] as? Double, px.isFinite, px >= 0,
               let shifts = params?["shifts"] as? Double, shifts.isFinite, shifts >= 0 {
                self = .launchSettle(settledAt: Date(timeIntervalSince1970: epochMs / 1_000), maxMovePx: px,
                                     element: params?["element"] as? String ?? "other", shifts: Int(min(shifts, 1_000_000)))
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
                self = .openTab(AgentPaneOpenTab(kind: kind, text: String(text.prefix(Self.maximumOpenTabText)), cwd: kind == .terminal ? cwd : nil,
                                                 search: kind == .browser && params?["search"] as? Bool == true,
                                                 run: kind != .terminal || params?["run"] as? Bool != false,
                                                 keep: params?["keep"] as? Bool == true,
                                                 profile: kind == .browser ? AgentPaneOpenTabProfile(params: params) : nil,
                                                 inPlace: params?["inPlace"] as? Bool == true,
                                                 beside: kind == .browser && params?["beside"] as? Bool == true))
            } else {
                self = .unsupported(method)
            }
        case "run.attach":
            self = AgentPaneRunAttach(params: params ?? [:]).map(AgentPaneRequest.runAttach) ?? .invalidRunAttach
        case "tab.typeAhead":
            if let text = params?["text"] as? String {
                self = .typeAhead(String(text.prefix(Self.maximumOpenTabText)))
            } else {
                self = .unsupported(method)
            }
        case "account.add":
            self = AgentPaneAddAccount(params: params).map(AgentPaneRequest.addAccount) ?? .unsupported(method)
        case "harness.update":
            // Harness ids (profile file names), never a command: one `id`, or `ids` for Update all.
            let harnessId = { (value: Any?) -> String? in
                guard let id = value as? String, !id.isEmpty, id.utf8.count <= 128,
                      id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
                return id
            }
            if let id = harnessId(params?["id"]) {
                self = .harnessUpdate(ids: [id], each: false)
            } else if let list = params?["ids"] as? [Any], (1 ... 32).contains(list.count) {
                let ids = list.compactMap(harnessId)
                self = ids.count == list.count && Set(ids).count == ids.count ? .harnessUpdate(ids: ids, each: true) : .unsupported(method)
            } else {
                self = .unsupported(method)
            }
        case "acpmux.restart":
            self = .restartAcpmux
        case "harness.restart":
            self = .harnessRestart
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
        case "newTab.context":
            self = .newTabContext
        case "newTab.warm":
            // The page's own JSON text (newtab/warmSnapshot.ts), kept as it is: one list has one text, so the pages of one
            // list share one part (``AgentPaneNewTabShared``). No parse and sorted re-encode of up to 512 KB on main.
            if let text = params?["warm"] as? String, !text.isEmpty, text.utf8.count <= AgentPaneNewTab.maximumWarmBytes {
                self = .newTabWarm(text)
            } else {
                self = .unsupported(method)
            }
        case "newTab.setTemplate":
            if let template = params?["template"] as? String, !template.isEmpty, template.count <= 32 {
                self = .editNewTab(.template(template))
            } else {
                self = .unsupported(method)
            }
        case "readAloud.speak", "readAloud.stop":
            self = AgentPaneReadAloud.Command(method: method, params: params).map(AgentPaneRequest.readAloud) ?? .unsupported(method)
        case "nowPlaying.command":
            if let command = AgentPaneNowPlaying.Command(params) { self = .nowPlaying(command) } else { self = .unsupported(method) }
        case "newTab.remember":
            // One input (R86): the agent pick, and the model picked on it in `folder`.
            if let agent = params?["agent"] as? String, !agent.isEmpty, agent.count <= 128 {
                let model = (params?["model"] as? String).flatMap { !$0.isEmpty && $0.count <= 256 ? $0 : nil }
                let folder = (params?["folder"] as? String).flatMap { !$0.isEmpty && $0.count <= 4096 ? $0 : nil }
                self = .rememberNewTab(AgentPaneRememberedPick(agent: agent, model: model, folder: folder))
            } else if let started = params?["started"] as? String, started.hasPrefix("/"), started.count <= 4096 {
                // The project of a chat the person picked and started (a page choice like the agent pick).
                var pick = AgentPaneRememberedPick(agent: "")
                pick.started = started
                self = .rememberNewTab(pick)
            } else if params?["harnessHint"] as? String == "dismissed" {
                // Integrate a harness dismissed for good (a page choice like the agent pick).
                var pick = AgentPaneRememberedPick(agent: "")
                pick.dismissesHarnessHint = true
                self = .rememberNewTab(pick)
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
        case "project.browse": self = .browseProject
        case "sandbox.state": self = .sandboxState(wait: params?["wait"] as? Bool == true)
        case "cloud.handoffTurn":
            // The store's session ids only (`SESSION` in backend handoffs/routes.ts).
            guard let session = params?["sessionId"] as? String,
                  session.range(of: #"^[A-Za-z0-9_.:-]{1,128}$"#, options: .regularExpression) != nil else {
                self = .unsupported(method)
                return
            }
            self = .cloudHandoffTurn(sessionId: session)
        case "cloud.signInCancel": self = .cloudSignInCancel(expired: params?["expired"] as? Bool == true)
        case "cloud.plan.subscribe":
            // Only the plans the cards may name; anything else is refused here.
            if let plan = params?["plan"] as? String, AgentPaneCloudMachines.Plan.subscribable.contains(plan) { self = .cloudPlanSubscribe(plan: plan) } else { self = .unsupported(method) }
        case "cloud.signIn":
            // The start's key only (`AgentPaneCloudStart`'s): the start itself goes after, as `cloud.startChat`.
            if let key = params?["key"] as? String, UUID(uuidString: key) != nil { self = .cloudSignIn(key: key) } else { self = .unsupported(method) }
        case "cloud.setUp":
            // The start's key, one of the card's ways in and the family it waits for (CloudSetup).
            if let key = params?["key"] as? String, UUID(uuidString: key) != nil, let action = params?["action"] as? String,
               CloudSetup.Action(rawValue: action) != nil, let family = params?["family"] as? String, CloudSetup.families.contains(family) {
                self = .cloudSetUp(key: key, action: action, family: family)
            } else { self = .unsupported(method) }
        case "cloud.startChat": self = AgentPaneCloudStart(params: params).map(Self.cloudStartChat) ?? .unsupported(method)
        case "cloud.repickChat": self = AgentPaneCloudRepick(params: params).map(Self.cloudRepickChat) ?? .unsupported(method)
        case "cloud.answerStart": self = AgentPaneCloudAnswer(params: params).map(Self.cloudAnswerStart) ?? .unsupported(method)
        case "sandbox.run":
            // The task is the person's prompt (never logged); the server checks the agent by name.
            let agent = params?["agent"] as? String
            if let task = params?["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               task.count <= Self.maximumSandboxTask, agent.map({ !$0.isEmpty && $0.count <= 32 }) ?? true,
               let key = params?["key"] as? String, UUID(uuidString: key) != nil {
                self = .sandboxRun(task: task, agent: agent, key: key)
            } else {
                self = .unsupported(method)
            }
        case "workspace.chooseFolder": self = .chooseFolder
        case "chat.folder.choose": self = .chooseChatFolder
        case "machine.share.self": self = .shareMachineWithMe
        case "share.op":
            // As `action.run`: a `session` that is there must be a usable id, never dropped.
            let session = params?["session"].map { $0 as? String }
            if let op = AgentPaneShareOp(params: params), session.map({ $0.map { !$0.isEmpty && $0.count <= 256 } ?? false }) ?? true {
                self = .shareOp(op, session: session ?? nil)
            } else {
                self = .unsupported(method)
            }
        case "chat.attach.choose": self = .chooseAttachments
        case "chat.attach.dropped":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneDroppedPaths.Kind.init(rawValue:)),
               let names = params?["names"] as? [String], !names.isEmpty,
               names.allSatisfy(AgentPaneDroppedPaths.isAskedName) {
                // The page's `Date.now()` when it took the gesture (ms); absent from an older page.
                let gestureAt = (params?["gestureAt"] as? NSNumber).map { $0.doubleValue / 1000 }.flatMap { $0.isFinite ? $0 : nil }
                self = .attachDropped(kind, names: names, gestureAt: gestureAt)
            } else {
                self = .unsupported(method)
            }
        case "chat.attach.source":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneDroppedPaths.Kind.init(rawValue:)),
               let names = params?["names"] as? [String], !names.isEmpty,
               names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) {
                // The page's `Date.now()` when it took the gesture (ms); absent from an older page.
                let gestureAt = (params?["gestureAt"] as? NSNumber).map { $0.doubleValue / 1000 }.flatMap { $0.isFinite ? $0 : nil }
                self = .attachSource(kind, names: names, gestureAt: gestureAt)
            } else {
                self = .unsupported(method)
            }
        case "chat.attach.external": self = .attachExternal
        case "attachment.sourceIcon":
            if let bundleId = params?["bundleId"] as? String, AttachmentSource.isBundleId(bundleId) { self = .attachmentSourceIcon(bundleId) }
            else { self = .unsupported(method) }
        case "workspace.useFolder":
            // Any text: a path that is not an existing absolute folder is refused by the host
            // (`transport.path_invalid`), so the page never takes it for an older host.
            if let cwd = params?["cwd"] as? String, cwd.utf8.count <= Self.maximumOpenTabText {
                self = .useFolder(cwd, confirm: params?["confirm"] as? Bool == true)
            } else {
                self = .unsupported(method)
            }
        case "project.list":
            let query = (params?["query"] as? String).map { String($0.prefix(512)) }
            self = .listProjects(query)
        case "agent.avatar", "agent.avatar.set", "agent.avatar.remove":
            // A session id is short; anything else never names a stored avatar.
            if let session = params?["sessionId"] as? String, !session.isEmpty, session.utf8.count <= 256 {
                self = method == "agent.avatar" ? .agentAvatar(session) : method == "agent.avatar.set" ? .setAgentAvatar(session) : .removeAgentAvatar(session)
            } else { self = .unsupported(method) }
        case "agent.mini":
            self = .miniSubject
        case "agent.mini.show":
            // A session id is short; null (or absent) is the Chief.
            if let session = params?["sessionId"] as? String {
                self = !session.isEmpty && session.utf8.count <= 256 ? .showInMini(session) : .unsupported(method)
            } else { self = .showInMini(nil) }
        case "chief.face":
            // A Chief's participant id (acpmux `fromChief`): `agent_` and a short token.
            if let chief = params?["chief"] as? String, chief.hasPrefix("agent_"), (7...64).contains(chief.utf8.count),
               chief.utf8.allSatisfy({ $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) {
                self = .chiefFace(chief)
            } else { self = .unsupported(method) }
        case "harness.symbol":
            if let name = params?["name"] as? String, HarnessSymbolImages.isSymbolName(name) { self = .harnessSymbol(name) }
            else { self = .unsupported(method) }
        case "folder.complete":
            if let path = params?["path"] as? String, AgentPaneFolderCompletion.isWellFormed(path) { self = .completeFolder(path) }
            else { self = .unsupported(method) }
        case "project.icon":
            if let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 { self = .projectIcon(cwd) }
            else { self = .unsupported(method) }
        case "chats.open":
            if let key = params?["key"] as? String, key.contains(":"), key.count <= 512 { self = .openChat(key) }
            else { self = .unsupported(method) }
        case "chats.resume":
            if let ref = params?["ref"] as? String, !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ref.utf8.count <= 4096 {
                self = .resumeChat(ref)
            } else { self = .unsupported(method) }
        case "chats.openInTerminal":
            if let key = params?["key"] as? String, key.contains(":"), key.count <= 512 { self = .openChatInTerminal(key) }
            else { self = .unsupported(method) }
        case "chats.watch":
            if let key = params?["key"] as? String, key.contains(":"), key.count <= 512 { self = .watchChat(key) }
            else { self = .unsupported(method) }
        case "chats.page": self = .chatsPage(AgentPaneChatsQuery(params: params))
        case "app.action":
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128 { self = .appAction(id) }
            else { self = .unsupported(method) }
        case "pane.action":
            if params?["id"] as? String == AgentPaneModel.previewAction {
                self = Self.preview(params, method: method)
            } else if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128 {
                let cwd = (params?["cwd"] as? String).flatMap(Self.headerFolder)
                let toggle = params?["mode"] as? String == "toggle"
                if id == AgentPaneModel.diffAction, let turn = AgentPaneDiffTurn(params: params?["turn"]) {
                    self = .diffTurn(turn, cwd: cwd, toggle: toggle)
                } else if id == AgentPaneModel.diffAction, let patch = AgentPaneDiffPatch(params: params?["patch"]) {
                    self = .diffPatch(patch, cwd: cwd, toggle: toggle)
                } else {
                    self = .paneAction(id, cwd: cwd, toggle: toggle)
                }
            } else {
                self = .unsupported(method)
            }
        case "pane.moveToMachine":
            if let machine = params?["machine"] as? String, !machine.isEmpty, machine.count <= 256,
               let session = params?["session"] as? String, !session.isEmpty, session.count <= 256 {
                self = .moveToMachine(machine, session: session)
            } else {
                self = .unsupported(method)
            }
        case "pane.tabState": self = .tabState(refresh: params?["refresh"] as? Bool == true, terminalSwitch: params?["terminalSwitch"] as? Bool == true)
        case "pane.tabRowTools":
            if let width = (params?["width"] as? NSNumber)?.doubleValue, width.isFinite, (0...2000).contains(width) {
                let need = (params?["need"] as? NSNumber)?.doubleValue
                self = .tabRowTools(width: width, need: need.flatMap { $0.isFinite && (0...2000).contains($0) ? $0 : nil })
            } else {
                self = .unsupported(method)
            }
        case "pane.sessionInfo":
            let info = params?["info"]
            if info == nil || info is NSNull { self = .sessionInfo(nil) }
            else if let model = AgentPaneSessionInfoModel.decode(info) { self = .sessionInfo(model) }
            else { self = .unsupported(method) }
        case "pane.sessionInfo.overlays":
            if let rects = AgentPaneSessionInfoOverlay.decode(params?["rects"]) { self = .sessionInfoOverlays(rects) }
            else { self = .unsupported(method) }
        case "pane.sessionInfo.pinch":
            if let pinch = AgentPaneSessionInfoPinch.decode(params) { self = .sessionInfoPinch(pinch) }
            else { self = .unsupported(method) }
        case "pane.toastAvoidance":
            if let rects = AgentPaneSessionInfoOverlay.decode(params?["rects"]), rects.count <= 1 { self = .toastAvoidance(rects.first) }
            else { self = .unsupported(method) }
        case "pane.toast":
            if let message = params?["message"] as? String, !message.isEmpty {
                self = .toast(message: message, isError: params?["tone"] as? String == "error", group: params?["group"] as? String)
            } else { self = .unsupported(method) }
        case "pane.glass":
            if let surfaces = AgentPaneHostGlassSurface.decode(params?["surfaces"], zoom: params?["zoom"]) { self = .hostGlass(surfaces) }
            else { self = .unsupported(method) }
        case "pane.copyText":
            if let text = params?["text"] as? String { self = .copyText(text) }
            else { self = .unsupported(method) }
        case "pane.tabRowTools.set":
            if let tools = AgentPaneTabRowTools.list(params?["tools"]) { self = .tabRowToolsSet(tools) }
            else { self = .unsupported(method) }
        case "customizations.menu":
            if let point = params?["point"] as? [String: Any],
               let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue,
               x.isFinite, y.isFinite { self = .customizationsMenu(x: x, y: y) }
            else { self = .unsupported(method) }
        case "pane.tabRowTools.openMenu":
            guard let id = params?["id"] as? String, id == "chat-menu",
                  let rawMenuItemID = params?["menuItemId"], !(rawMenuItemID is NSNull) else {
                if params?["menuItemId"] == nil || params?["menuItemId"] is NSNull,
                   params?["id"] as? String == "chat-menu" { self = .tabRowToolsOpenMenu(id: "chat-menu", menuItemID: nil) }
                else { self = .unsupported(method) }
                return
            }
            guard let menuItemID = rawMenuItemID as? String, !menuItemID.isEmpty,
                  menuItemID.utf8.count <= 256, menuItemID.count <= 64 else { self = .unsupported(method); return }
            self = .tabRowToolsOpenMenu(id: id, menuItemID: menuItemID)
        case "pane.setQuickActions":
            if let list = AgentPaneQuickAction.list(params?["quickActions"]) { self = .setQuickActions(list) }
            else { self = .unsupported(method) }
        case "chat.btw.inline":
            if let question = params?["question"] as? String, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 32 * 1024,
               let sessionId = params?["sessionId"] as? String, !sessionId.isEmpty, sessionId.utf8.count <= 256 {
                self = .btwInline(question: question, sessionId: sessionId)
            } else { self = .unsupported(method) }
        case "chat.sideChat":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 {
                self = .sideChat(id, splitRight: params?["split"] as? String == "right")
            } else { self = .unsupported(method) }
        case "chat.subagentPane":
            if let id = params?["subagent"] as? String, !id.isEmpty, id.count <= 256 {
                // `title`: the subagent's own name, which its pane's tab shows (SubagentTabTitles).
                self = .subagentPane(id, focus: params?["focus"] as? Bool == true, title: params?["title"] as? String, tone: params?["tone"] as? Int,
                                     mark: SubagentTabTitles.mark(params?["mark"]))
            } else { self = .unsupported(method) }
        case "chat.subagentShown":
            let id = params?["subagent"] as? String
            if let id, id.isEmpty || id.count > 256 { self = .unsupported(method) } else {
                self = .subagentShown(id, title: id == nil ? nil : params?["title"] as? String, tone: id == nil ? nil : params?["tone"] as? Int,
                                      facts: id == nil ? nil : SubagentTabFacts(params), mark: id == nil ? nil : SubagentTabTitles.mark(params?["mark"]))
            }
        case "chat.processTerminal":
            if let id = params?["toolCallId"] as? String, AgentPaneProcessViewer.isToken(id) { self = .processTerminal(toolCall: id) } else { self = .unsupported(method) }
        case "chat.newHere":
            if let cwd = (params?["cwd"] as? String).flatMap(Self.headerFolder) { self = .newChatHere(cwd) } else { self = .unsupported(method) }
        case AgentPaneTryAnotherApproach.method:
            self = AgentPaneTryAnotherApproach(params: params).map(AgentPaneRequest.tryAnotherApproach) ?? .unsupported(method)
        case AgentPaneCloudTurnRewind.checkpointMethod, AgentPaneCloudTurnRewind.rewindMethod:
            self = AgentPaneCloudTurnRewind(method: method, params: params).map(AgentPaneRequest.cloudTurnRewind) ?? .unsupported(method)
        case "chat.openTab":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 { self = .chatTab(id, AgentForkDestination(placement: params?["placement"] as? String)) } else { self = .unsupported(method) }
        case "chat.asks.open":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256, let place = AgentPaneAskPlace(params?["where"]), let there = AgentPaneAskThere(params) { self = .asksOpen(id, place, there) } else { self = .unsupported(method) }
        case "chat.attention.open":
            if let id = params?["tabId"] as? String, !id.isEmpty, id.utf8.count <= AgentPaneAttentionTabs.maximumTabID { self = .attentionOpen(id) } else { self = .unsupported(method) }
        case "chat.asks.answer":
            if let ask = AgentPaneAskAnswer(params) { self = .asksAnswer(ask) } else { self = .unsupported(method) }
        case "chat.offer.open":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 { self = .offerOpen(id, sender: params?["sender"] as? Bool == true) } else { self = .unsupported(method) }
        case "chat.upload":
            if let files = AgentPaneUpload.files(params) { self = .upload(files) } else { self = .unsupported(method) }
        case "chat.upload.begin", "chat.upload.chunk", "chat.upload.finish", "chat.upload.cancel":
            self = Self.uploadStage(method, params)
        case "chat.toolCard.respond":
            if let answer = AgentPaneToolCard.answer(params) { self = .toolCard(card: answer.card, action: answer.action, value: answer.value) } else { self = .unsupported(method) }
        case "chat.computerUsePreview":
            if let action = AgentPaneComputerUsePreview.action(params) { self = .computerUsePreview(action) } else { self = .unsupported(method) }
        case "shortcut.edit":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneTabKind.init(rawValue:)) {
                self = .editShortcut(kind)
            } else {
                self = .unsupported(method)
            }
        case "action.run":
            // A `session` that is there must be a usable id: a malformed one is refused, never
            // dropped (which would run the action on whatever the tab shows).
            let session = params?["session"].map { $0 as? String }
            // An `environment` is New Cloud Machine's only, and a Cloud environment id (`env_…`);
            // any other is refused, never dropped (which would make a machine in another one).
            let environment = params?["environment"].map { $0 as? String }
            // A `handoff` is New Cloud Chat's only, and a token; any other is refused, never dropped.
            let handoff = params?["handoff"].map { $0 as? String }
            // An `app` is the editor id of a folder action that opens one (Open in Editor, Open In ▸); any other
            // is refused, never dropped (which would open the default editor instead).
            let app = params?["app"].map { $0 as? String }
            // A `mode` is Chat Place's only (`chatPlace.set`): where the chat runs (local, cloud or auto); any other is refused.
            let mode = params?["mode"].map { $0 as? String }
            // A `priority` is Keep Running's only (`chatPriority.set`): high or normal; any other is refused.
            let priority = params?["priority"].map { $0 as? String }
            // `queued` and `hasDraft` are what the page knows of the chat's cargo (Chat Place's set and retry only); any other is refused.
            let queued = params?["queued"].map { $0 as? Int }
            let hasDraft = params?["hasDraft"].map { $0 as? Bool }
            // `sessions` names the chats a chat-list row or Evacuate acts on (never the tab's own chat, so the
            // shown-chat guard does not bind it): 1...500 usable ids, Evacuate, Bring Back and a row's place pick only.
            let sessions = params?["sessions"].map { $0 as? [String] }
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128,
               session.map({ $0.map { !$0.isEmpty && $0.count <= 256 } ?? false }) ?? true,
               environment.map({ $0.map { id == "newCloudMachine" && AgentPaneRequest.isCloudEnvironmentID($0) } ?? false }) ?? true,
               handoff.map({ $0.map { id == "palette.newCloudChat" && AgentPaneRequest.isHandoffToken($0) } ?? false }) ?? true,
               app.map({ $0.map { AgentPaneModel.editorActions.contains(id) && AgentPaneRequest.isEditorID($0) } ?? false }) ?? true,
               mode.map({ $0.map { id == "chatPlace.set" && ["local", "cloud", "auto"].contains($0) } ?? false }) ?? true,
               priority.map({ $0.map { id == "chatPriority.set" && ["high", "normal"].contains($0) } ?? false }) ?? true,
               queued.map({ $0.map { ["chatPlace.set", "chatMove.retry"].contains(id) && (0...100_000).contains($0) } ?? false }) ?? true,
               hasDraft.map({ $0 != nil && ["chatPlace.set", "chatMove.retry"].contains(id) }) ?? true,
               sessions.map({ $0.map { AgentPaneRequest.areSessionTargets($0, id: id, alongside: session ?? nil) } ?? false }) ?? true {
                // Connect GitHub's card names the failed call's repository and the chat's link: a
                // malformed one is dropped (Connect still runs, as from the palette); the link is
                // checked against this build's links where it runs (AgentPaneModel+Actions.swift).
                let github = id == "accounts.githubConnect"
                let repo = (params?["repo"] as? String).flatMap { github && AgentPaneRequest.isGitHubRepo($0) ? $0 : nil }
                let returnTo = (params?["returnTo"] as? String).flatMap { github && $0.utf8.count <= 512 ? $0 : nil }
                let org = (params?["org"] as? String).flatMap { github && AgentPaneRequest.isGitHubOwner($0) ? $0 : nil }
                self = .runAction(id, session: session ?? nil, environment: environment ?? nil, handoff: handoff ?? nil, app: app ?? nil,
                                  repo: repo, returnTo: returnTo, org: org,
                                  mode: mode ?? nil, queued: queued ?? nil, hasDraft: hasDraft ?? nil, sessions: sessions ?? nil, priority: priority ?? nil)
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
        case "cloud.preview.open":
            if let params, Set(params.keys) == ["port"],
               let port = params["port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
               Double(port.intValue) == port.doubleValue, (1...65535).contains(port.intValue) {
                self = .openCloudPreview(port: port.intValue)
            } else {
                self = .unsupported(method)
            }
        case "editors.list": self = .editorsList
        case "quick.dismiss": self = .quickDismiss
        case "quick.openInWindow":
            let id = params?["sessionId"] as? String
            self = .quickOpenInWindow(sessionId: id?.isEmpty == false ? id : nil)
        case "quick.startInBackground":
            self = AgentPaneQuickStart(params: params).map(AgentPaneRequest.quickStartInBackground) ?? .unsupported(method)
        case "quick.setOnTop": self = (params?["onTop"] as? Bool).map(AgentPaneRequest.quickSetOnTop) ?? .unsupported(method)
        case "quick.setCollapsed": self = (params?["collapsed"] as? Bool).map(AgentPaneRequest.quickSetCollapsed) ?? .unsupported(method)
        case "quick.floatingState": self = .quickFloatingState
        case "quick.context": self = .quickContext
        case "turn.undo": self = AgentPaneTurnUndo(params: params).map(AgentPaneRequest.turnUndo) ?? .invalidTurnUndo
        case "git.stage", "git.unstage", "git.stageHunk", "git.unstageHunk":
            self = .gitStage(AgentPaneGitStage(method: method, params: params))
        case "git.pullRequest": self = .gitPullRequest(AgentPaneGitPullRequest(params: params))
        case "project.instructions": self = .projectInstructions(AgentPaneProjectInstructions(params: params))
        case "project.addFiles": self = .projectAddFiles(AgentPaneProjectInstructions(params: params))
        case "composer.capture": self = .composerCapture(mode: params?["mode"] as? String)
        case "git.githubRepository":
            if let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") {
                self = .githubRepository(cwd: cwd)
            } else {
                self = .invalidGit(method)
            }
        case "git.diff", "git.status", "file.search", "git.checkpoint.diff", "git.worktree.setup":
            if let git = AgentPaneGitRequest(method: method, params: params) {
                self = .git(git)
            } else {
                self = .invalidGit(method)
            }
        case "git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove",
             "git.worktree.setup.run":
            self = AgentPaneGitWrite(method: method, params: params).map(AgentPaneRequest.gitWrite) ?? .invalidGit(method)
        case "transport.open": self = .transportOpen
        case "transport.gesture":
            var refusal: String?
            let intent = AgentPaneGestureIntent(gestureParams: params, refusal: &refusal)
            self = .transportGesture(intent, method: AgentPaneGestureIntent.method(gestureParams: params), refusal: refusal)
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
        case "transport.ack":
            if let connection = params?["connection"] as? Int, let seq = params?["seq"] as? Int {
                self = .transportAck(connection: connection, seq: seq, inputPending: params?["inputPending"] as? Bool ?? false)
            } else {
                self = .unsupported(method)
            }
        case "externalAccess.openSettings":
            if let params, let raw = params["kind"] as? String, let kind = AgentPaneExternalAccessKind(rawValue: raw),
               Set(params.keys) == ["kind"] {
                self = .externalAccessOpenSettings(kind)
            } else {
                self = .unsupported(method)
            }
        case "dictation.toggle": self = .dictation(.toggle)
        case "dictation.handoff": self = .dictationHandoff
        case "dictation.sources": self = .dictationSources
        case "dictation.start": self = .dictation(.start)
        case "dictation.stop": self = .dictation(.stop)
        case "dictation.cancel": self = .dictation(.cancel)
        case "dictation.audio":
            if let enabled = params?["enabled"] as? Bool {
                self = .dictation(.recordAudio(enabled))
            } else {
                self = .unsupported(method)
            }
        case "dictation.recording.upload", "dictation.recording.cancel":
            if let path = params?["path"] as? String, path.hasPrefix("/"), path.utf8.count <= 4096 {
                self = method == "dictation.recording.upload" ? .dictationRecordingUpload(path: path) : .dictationRecordingCancel(path: path)
            } else {
                self = .unsupported(method)
            }
        case "dictation.openSettings":
            if let raw = params?["permission"] as? String, let permission = DictationPermission(rawValue: raw) {
                self = .dictation(.openSettings(permission))
            } else {
                self = .unsupported(method)
            }
        case _ where AgentPaneEnvironmentRequest.methods.contains(method):
            self = AgentPaneEnvironmentRequest(method: method, params: params).map(AgentPaneRequest.environment) ?? .unsupported(method)
        case _ where AgentPaneCloudMachineRequest.methods.contains(method):
            self = AgentPaneCloudMachineRequest(method: method, params: params).map(AgentPaneRequest.cloudMachine) ?? .unsupported(method)
        case _ where AgentPaneReplyRequest.methods.contains(method):
            self = AgentPaneReplyRequest(method: method, params: params).map(AgentPaneRequest.reply) ?? .unsupported(method)
        default:
            self = .unsupported(method)
        }
    }
}
