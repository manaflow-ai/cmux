import CmuxNextCloud
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

    /// Decodes a `WKScriptMessage.body` (a dictionary once bridged).
    init(delegated body: Any) {
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
        case "run.attach":
            self = AgentPaneRunAttach(params: params ?? [:]).map(AgentPaneRequest.runAttach) ?? .invalidRunAttach
        case "account.add":
            self = AgentPaneAddAccount(params: params).map(AgentPaneRequest.addAccount) ?? .unsupported(method)
        case "readAloud.speak", "readAloud.stop":
            self = AgentPaneReadAloud.Command(method: method, params: params).map(AgentPaneRequest.readAloud) ?? .unsupported(method)
        case "nowPlaying.command":
            if let command = AgentPaneNowPlaying.Command(params) { self = .nowPlaying(command) } else { self = .unsupported(method) }
        case "cloud.plan.subscribe":
            // Only the plans the cards may name; anything else is refused here.
            if let plan = params?["plan"] as? String, AgentPaneCloudMachines.Plan.subscribable.contains(plan) { self = .cloudPlanSubscribe(plan: plan) } else { self = .unsupported(method) }
        case "cloud.setUp":
            // The start's key, one of the card's ways in and the family it waits for (CloudSetup).
            if let key = params?["key"] as? String, UUID(uuidString: key) != nil, let action = params?["action"] as? String,
               CloudSetup.Action(rawValue: action) != nil, let family = params?["family"] as? String, CloudSetup.families.contains(family) {
                self = .cloudSetUp(key: key, action: action, family: family)
            } else { self = .unsupported(method) }
        case "cloud.startChat": self = AgentPaneCloudStart(params: params).map(Self.cloudStartChat) ?? .unsupported(method)
        case "cloud.repickChat": self = AgentPaneCloudRepick(params: params).map(Self.cloudRepickChat) ?? .unsupported(method)
        case "cloud.answerStart": self = AgentPaneCloudAnswer(params: params).map(Self.cloudAnswerStart) ?? .unsupported(method)
        case "share.op":
            // As `action.run`: a `session` that is there must be a usable id, never dropped.
            let session = params?["session"].map { $0 as? String }
            if let op = AgentPaneShareOp(params: params), session.map({ $0.map { !$0.isEmpty && $0.count <= 256 } ?? false }) ?? true {
                self = .shareOp(op, session: session ?? nil)
            } else {
                self = .unsupported(method)
            }
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
        case "chats.page": self = .chatsPage(AgentPaneChatsQuery(params: params))
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
        case "pane.glass":
            if let surfaces = AgentPaneHostGlassSurface.decode(params?["surfaces"], zoom: params?["zoom"]) { self = .hostGlass(surfaces) }
            else { self = .unsupported(method) }
        case "pane.tabRowTools.set":
            if let tools = AgentPaneTabRowTools.list(params?["tools"]) { self = .tabRowToolsSet(tools) }
            else { self = .unsupported(method) }
        case "pane.setQuickActions":
            if let list = AgentPaneQuickAction.list(params?["quickActions"]) { self = .setQuickActions(list) }
            else { self = .unsupported(method) }
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
        case AgentPaneTryAnotherApproach.method:
            self = AgentPaneTryAnotherApproach(params: params).map(AgentPaneRequest.tryAnotherApproach) ?? .unsupported(method)
        case AgentPaneCloudTurnRewind.checkpointMethod, AgentPaneCloudTurnRewind.rewindMethod:
            self = AgentPaneCloudTurnRewind(method: method, params: params).map(AgentPaneRequest.cloudTurnRewind) ?? .unsupported(method)
        case "chat.asks.open":
            if let id = params?["sessionId"] as? String, !id.isEmpty, id.count <= 256, let place = AgentPaneAskPlace(params?["where"]), let there = AgentPaneAskThere(params) { self = .asksOpen(id, place, there) } else { self = .unsupported(method) }
        case "chat.asks.answer":
            if let ask = AgentPaneAskAnswer(params) { self = .asksAnswer(ask) } else { self = .unsupported(method) }
        case "chat.upload":
            if let files = AgentPaneUpload.files(params) { self = .upload(files) } else { self = .unsupported(method) }
        case "chat.upload.begin", "chat.upload.chunk", "chat.upload.finish", "chat.upload.cancel":
            self = Self.uploadStage(method, params)
        case "chat.toolCard.respond":
            if let answer = AgentPaneToolCard.answer(params) { self = .toolCard(card: answer.card, action: answer.action, value: answer.value) } else { self = .unsupported(method) }
        case "chat.computerUsePreview":
            if let action = AgentPaneComputerUsePreview.action(params) { self = .computerUsePreview(action) } else { self = .unsupported(method) }
        case "quick.startInBackground":
            self = AgentPaneQuickStart(params: params).map(AgentPaneRequest.quickStartInBackground) ?? .unsupported(method)
        case "turn.undo": self = AgentPaneTurnUndo(params: params).map(AgentPaneRequest.turnUndo) ?? .invalidTurnUndo
        case "git.stage", "git.unstage", "git.stageHunk", "git.unstageHunk":
            self = .gitStage(AgentPaneGitStage(method: method, params: params))
        case "git.pullRequest": self = .gitPullRequest(AgentPaneGitPullRequest(params: params))
        case "project.instructions": self = .projectInstructions(AgentPaneProjectInstructions(params: params))
        case "project.addFiles": self = .projectAddFiles(AgentPaneProjectInstructions(params: params))
        case "git.diff", "git.status", "file.search", "git.checkpoint.diff", "git.worktree.setup":
            if let git = AgentPaneGitRequest(method: method, params: params) {
                self = .git(git)
            } else {
                self = .invalidGit(method)
            }
        case "git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove",
             "git.worktree.setup.run":
            self = AgentPaneGitWrite(method: method, params: params).map(AgentPaneRequest.gitWrite) ?? .invalidGit(method)
        case "transport.gesture":
            var refusal: String?
            let intent = AgentPaneGestureIntent(gestureParams: params, refusal: &refusal)
            self = .transportGesture(intent, method: AgentPaneGestureIntent.method(gestureParams: params), refusal: refusal)
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
