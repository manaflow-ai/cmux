import CmuxNextDictation
import CmuxNextSettings
import Foundation

extension AgentPaneRequest {
    private static let maximumUploadStageChunk = 512 * 1024

    private static func uploadStage(_ method: String, _ params: [String: Any]?) -> AgentPaneRequest {
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
            return .uploadStage(.begin(name: name, size: size, batchToken: batchToken, batch: batch))
        case "chat.upload.chunk":
            guard let token = params["token"] as? String, (1...128).contains(token.utf8.count),
                  let offset = (params["offset"] as? NSNumber)?.intValue, offset >= 0,
                  let text = params["data"] as? String,
                  text.utf8.count <= (maximumUploadStageChunk / 3 + 1) * 4,
                  let data = Data(base64Encoded: text), data.count <= maximumUploadStageChunk else { return .unsupported(method) }
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
    /// (``Foundation/URL/isAgentPanePreview``, as the preview card's `browser.open`) reaches the App.
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
        if AgentPaneCloudEnvironmentRequest.methods.contains(method) {
            self = AgentPaneCloudEnvironmentRequest(method: method, params: params).map(Self.cloudEnvironment) ?? .unsupported(method)
            return
        }
        if AgentPaneCloudRepositoryRequest.methods.contains(method) {
            self = AgentPaneCloudRepositoryRequest(method: method, params: params).map(Self.cloudRepository) ?? .unsupported(method)
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
        case "chat.unsentDraft":
            if let text = params?["text"] as? String {
                self = .unsentDraft(text)
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
            self = .painted(fromKeptTail: params?["drewKeptTail"] as? Bool ?? false)
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
                                                 keep: params?["keep"] as? Bool == true))
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
            // A harness id (profile file name), never a command.
            if let id = params?["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
               id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
                self = .harnessUpdate(id: id)
            } else {
                self = .unsupported(method)
            }
        case "acpmux.restart":
            self = .restartAcpmux
        case "acpmux.restartStuck":
            self = .restartStuckAcpmux
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
            if let warm = params?["warm"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: warm),
               data.count <= AgentPaneNewTab.maximumWarmBytes, let text = String(data: data, encoding: .utf8) {
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
        case "newTab.editWidgets":
            self = AgentPaneNewTabEdit(widgetParams: params).map(AgentPaneRequest.editNewTab) ?? .unsupported(method)
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
        case "cloud.startChat": self = AgentPaneCloudStart(params: params).map(Self.cloudStartChat) ?? .unsupported(method)
        case "cloud.repickChat": self = AgentPaneCloudRepick(params: params).map(Self.cloudRepickChat) ?? .unsupported(method)
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
        case "chat.attach.choose": self = .chooseAttachments
        case "chat.attach.dropped":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneDroppedPaths.Kind.init(rawValue:)),
               let names = params?["names"] as? [String], (1...AgentPaneDroppedPaths.maximumNames).contains(names.count),
               names.allSatisfy(AgentPaneDroppedPaths.isAskedName) {
                self = .attachDropped(kind, names: names)
            } else {
                self = .unsupported(method)
            }
        case "chat.attach.source":
            if let kind = (params?["kind"] as? String).flatMap(AgentPaneDroppedPaths.Kind.init(rawValue:)),
               let names = params?["names"] as? [String], (1...AgentPaneDroppedPaths.maximumNames).contains(names.count),
               names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) {
                // The page's `Date.now()` when it took the gesture (ms); absent from an older page.
                let gestureAt = (params?["gestureAt"] as? NSNumber).map { $0.doubleValue / 1000 }.flatMap { $0.isFinite ? $0 : nil }
                self = .attachSource(kind, names: names, gestureAt: gestureAt)
            } else {
                self = .unsupported(method)
            }
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
        case "chief.face":
            // A Chief's participant id (acpmux `fromChief`): `agent_` and a short token.
            if let chief = params?["chief"] as? String, chief.hasPrefix("agent_"), (7...64).contains(chief.utf8.count),
               chief.utf8.allSatisfy({ $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) {
                self = .chiefFace(chief)
            } else { self = .unsupported(method) }
        case "harness.symbol":
            if let name = params?["name"] as? String, HarnessSymbolImages.isSymbolName(name) { self = .harnessSymbol(name) }
            else { self = .unsupported(method) }
        case "project.icon":
            if let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 { self = .projectIcon(cwd) }
            else { self = .unsupported(method) }
        case "chats.open":
            if let key = params?["key"] as? String, key.contains(":"), key.count <= 512 { self = .openChat(key) }
            else { self = .unsupported(method) }
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
        case "pane.tabState": self = .tabState(refresh: params?["refresh"] as? Bool == true)
        case "pane.tabRowTools":
            if let width = (params?["width"] as? NSNumber)?.doubleValue, width.isFinite, (0...2000).contains(width) {
                self = .tabRowTools(width: width)
            } else {
                self = .unsupported(method)
            }
        case "pane.tabRowTools.set":
            if let tools = AgentPaneTabRowTools.list(params?["tools"]) { self = .tabRowToolsSet(tools) }
            else { self = .unsupported(method) }
        case "pane.setQuickActions":
            if let list = AgentPaneQuickAction.list(params?["quickActions"]) { self = .setQuickActions(list) }
            else { self = .unsupported(method) }
        case "chat.btw.inline":
            if let question = params?["question"] as? String, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 32 * 1024,
               let sessionId = params?["sessionId"] as? String, !sessionId.isEmpty, sessionId.utf8.count <= 256 {
                self = .btwInline(question: question, sessionId: sessionId)
            } else { self = .unsupported(method) }
        case "chat.sideChat":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 { self = .sideChat(id) } else { self = .unsupported(method) }
        case "chat.subagentPane":
            if let id = params?["subagent"] as? String, !id.isEmpty, id.count <= 256 {
                // `title`: the subagent's own name, which its pane's tab shows (SubagentTabTitles).
                self = .subagentPane(id, focus: params?["focus"] as? Bool == true, title: params?["title"] as? String)
            } else { self = .unsupported(method) }
        case "chat.subagentShown":
            let id = params?["subagent"] as? String
            if let id, id.isEmpty || id.count > 256 { self = .unsupported(method) } else {
                self = .subagentShown(id, title: id == nil ? nil : params?["title"] as? String)
            }
        case "chat.processTerminal":
            if let id = params?["toolCallId"] as? String, AgentPaneProcessViewer.isToken(id) { self = .processTerminal(toolCall: id) } else { self = .unsupported(method) }
        case "chat.newHere":
            if let cwd = (params?["cwd"] as? String).flatMap(Self.headerFolder) { self = .newChatHere(cwd) } else { self = .unsupported(method) }
        case "chat.openTab":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 { self = .chatTab(id, AgentForkDestination(placement: params?["placement"] as? String)) } else { self = .unsupported(method) }
        case "chat.asks.open":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256 { self = .asksOpen(id) } else { self = .unsupported(method) }
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
            if let id = params?["id"] as? String, !id.isEmpty, id.count <= 128,
               session.map({ $0.map { !$0.isEmpty && $0.count <= 256 } ?? false }) ?? true {
                self = .runAction(id, session: session ?? nil)
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
        case "git.diff", "git.status", "file.search", "git.checkpoint.diff":
            if let git = AgentPaneGitRequest(method: method, params: params) {
                self = .git(git)
            } else {
                self = .invalidGit(method)
            }
        case "git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove":
            self = AgentPaneGitWrite(method: method, params: params).map(AgentPaneRequest.gitWrite) ?? .invalidGit(method)
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
        case AgentPaneCloudCredentialTransferRequest.method:
            self = AgentPaneCloudCredentialTransferRequest(params: params).map(AgentPaneRequest.cloudCredentialTransfer) ?? .unsupported(method)
        case _ where AgentPaneReplyRequest.methods.contains(method):
            self = AgentPaneReplyRequest(method: method, params: params).map(AgentPaneRequest.reply) ?? .unsupported(method)
        default:
            self = .unsupported(method)
        }
    }
}
