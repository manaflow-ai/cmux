import AppKit
import CmuxChief
import CmuxControlSocket
import CmuxHomeCore
import Foundation
import MessagesLabHome

/// `chief.*`: the local Chief from the socket and `cmux chief`.
///
/// Every method runs on the socket worker (`ControlCommandExecutionPolicy`):
/// parameters are validated there, owner reads and writes await the
/// ``ChiefConversationOwner`` actor, and only the app-state parts (starting
/// the service, the store's send, window lookup, the transcript debug
/// helpers) hop to the main actor. None is in the remote relay allowlist
/// (`RemoteRelayCommandPolicy` denies by default): they read and write the
/// user's local Chief conversations and can start Chief turns, which run
/// commands on this Mac.
extension TerminalController {
    nonisolated func chiefResponse(_ request: ControlRequest) async -> String {
        let result = await chiefResult(request)
        return Self.v2Encoder.response(id: request.id, Self.controlCallResult(fromLegacy: result))
    }

    private nonisolated func chiefResult(_ request: ControlRequest) async -> V2CallResult {
        // Defense in depth: the relay policy already denies `chief.*`.
        if request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil {
            return .err(code: "not_authorized",
                        message: String(localized: "socket.chief.error.remoteDenied",
                                        defaultValue: "Chief is not available through a remote session."),
                        data: nil)
        }
        let params = request.params.mapValues(\.foundationObject)
        let parsed: ChiefControlRequest
        switch ChiefControlRequest.parse(method: request.method, params: params) {
        case .success(let value): parsed = value
        case .failure(let error):
            if case .unknownMethod = error { return Self.chiefUnknownMethod }
            return .err(code: "invalid_params", message: error.message, data: error.parameter.map { ["param": $0] })
        }
        do {
            switch parsed {
            case .open(let target):
                return try await chiefOpen(target)
            case .send(let text, let conversation, let from, let startTurn):
                if let from {
                    let owner = try await chiefOwner()
                    let id = try await Self.chiefOwnerCall {
                        try await owner.postExternal(conversation: conversation.map(ConversationID.init(_:)), from: from,
                                                     text: text, startTurn: startTurn)
                    }
                    return .ok(["conversation": conversation ?? ChiefConversationOwner.defaultConversationID.rawValue,
                                "message_id": id.rawValue, "queued": false, "from": from] as [String: Any])
                }
                let sent = try await Self.chiefSendAsUser(text: text, conversation: conversation)
                var payload: [String: Any] = ["conversation": sent.conversation, "queued": sent.queued]
                if let id = sent.messageID { payload["message_id"] = id }
                return .ok(payload)
            case .status:
                let status = try await v2MainAsync { ChiefService.shared.controlStatus() }
                return .ok(Self.chiefPayload(status))
            case .conversations:
                let rows = try await v2MainAsync { ChiefService.shared.controlConversations() }
                return .ok(["conversations": rows.map { Self.chiefPayload($0) }])
            case .read(let conversation, let limit):
                let owner = try await chiefOwner()
                let id = conversation.map(ConversationID.init(_:)) ?? ChiefConversationOwner.defaultConversationID
                let page = try await Self.chiefOwnerCall { try await owner.snapshot(of: id, tail: limit) }
                let messages = page.messages.map { ChiefControlMessage($0, participants: page.conversation.participants) }
                let working = await owner.isWorking(id)
                return .ok(["conversation": id.rawValue, "working": working,
                            "messages": messages.map { Self.chiefPayload($0) }] as [String: Any])
            case .stop(let conversation):
                let owner = try await chiefOwner()
                let id = conversation.map(ConversationID.init(_:)) ?? ChiefConversationOwner.defaultConversationID
                _ = try await Self.chiefOwnerCall { try await owner.snapshot(of: id, tail: 1) }
                let stopped = await owner.stopTurn(conversation: id)
                return .ok(["conversation": id.rawValue, "stopped": stopped] as [String: Any])
            case .approve(let conversation, let request, let choice):
                // Release builds answer approval cards only in Home (ChiefControlRequest.isAvailable).
                guard ChiefControlRequest.isAvailable("chief.approve") else {
                    return .err(code: "not_available",
                                message: String(localized: "socket.chief.error.approveNotAvailable",
                                                defaultValue: "Answer Chief's approvals in Home; this build doesn't accept them from the socket."),
                                data: nil)
                }
                let owner = try await chiefOwner()
                let id = conversation.map(ConversationID.init(_:)) ?? ChiefConversationOwner.defaultConversationID
                _ = try await Self.chiefOwnerCall { try await owner.snapshot(of: id, tail: 1) }
                guard let card = await owner.pendingApproval(in: id, request: request) else {
                    return .err(code: "not_found",
                                message: request == nil
                                    ? String(localized: "socket.chief.error.noPendingApproval", defaultValue: "Chief has no approval waiting.")
                                    : String(localized: "socket.chief.error.unknownApproval", defaultValue: "No Chief approval has that id."),
                                data: request.map { ["request": $0] })
                }
                // "allow", "DENY": the approval's own option of that name.
                let option = card.ref.options.first { $0.caseInsensitiveCompare(choice) == .orderedSame } ?? choice
                // The card found above, by its place: a request id alone can name another turn's card.
                try await Self.chiefOwnerCall {
                    try await owner.answerApproval(conversation: id, message: card.message, part: card.part, choice: option)
                }
                return .ok(["conversation": id.rawValue, "request": card.request, "choice": option, "decided": true] as [String: Any])
            case .answer(let conversation, let message, let choices, let text):
                // Release builds answer question cards only in Home (ChiefControlRequest.isAvailable).
                guard ChiefControlRequest.isAvailable("chief.answer") else {
                    return .err(code: "not_available",
                                message: String(localized: "socket.chief.error.answerNotAvailable",
                                                defaultValue: "Answer Chief's questions in Home; this build doesn't accept them from the socket."),
                                data: nil)
                }
                let owner = try await chiefOwner()
                let id = conversation.map(ConversationID.init(_:)) ?? ChiefConversationOwner.defaultConversationID
                _ = try await Self.chiefOwnerCall { try await owner.snapshot(of: id, tail: 1) }
                guard let card = await owner.pendingQuestion(in: id, message: message) else {
                    return .err(code: "not_found",
                                message: message == nil
                                    ? String(localized: "socket.chief.error.noPendingQuestion", defaultValue: "Chief has no question waiting.")
                                    : String(localized: "socket.chief.error.unknownQuestion",
                                             defaultValue: "No waiting Chief question is in that message."),
                                data: message.map { ["message": $0] })
                }
                let lines: [String]
                do {
                    // The same HomeOp.answerQuestion the card's Submit sends.
                    lines = try await Self.chiefOwnerCall {
                        try await owner.answerQuestion(card, in: id, choices: choices, text: text)
                    }
                } catch let problem as ChiefQuestionAnswer.Problem {
                    return .err(code: "invalid_params", message: Self.chiefAnswerProblemMessage(problem), data: nil)
                }
                return .ok(["conversation": id.rawValue, "message": card.message.rawValue,
                            "answer": lines] as [String: Any])
            case .debug(let action, let conversation):
#if DEBUG
                return try await chiefDebug(action, conversation: conversation)
#else
                _ = (action, conversation)
                return Self.chiefUnknownMethod
#endif
            }
        } catch let failure as ChiefControlFailure {
            return .err(code: failure.code, message: failure.message, data: nil)
        } catch {
            return Self.agentMessageMainHopFailure(error)
        }
    }

    // MARK: - Methods

    /// `chief.open`: an explicit focus-intent command (`focusIntentV2Methods`),
    /// like `workspace.select`. Home becomes the target window's content
    /// through ``ChiefHomeNavigation`` (the same path as the shortcut and the
    /// sidebar row); the window comes forward only when the
    /// command's focus policy allows it.
    private nonisolated func chiefOpen(_ target: ChiefControlWindowTarget) async throws -> V2CallResult {
        guard try await v2MainAsync({ ChiefSettings.isEnabled }) else {
            return .ok(["opened": false])
        }
        let windowID: UUID?? = try await v2MainAsync { () -> UUID?? in
            guard let app = AppDelegate.shared else { return .some(nil) }
            let tabManager: TabManager?
            if let raw = target.windowID {
                guard let id = self.v2UUIDAny(raw) else { return nil }
                tabManager = app.tabManagerFor(windowId: id)
                if tabManager == nil { return nil }
            } else if let raw = target.workspaceID, let workspace = self.v2UUIDAny(raw),
                      let owner = app.tabManagerFor(tabId: workspace) {
                tabManager = owner
            } else {
                tabManager = app.currentScriptableMainWindow()?.tabManager
            }
            guard let tabManager, let windowID = app.windowId(for: tabManager),
                  app.mainWindow(for: windowID) != nil,
                  let context = app.mainWindowContext(for: tabManager) else { return .some(nil) }
            // Complete the native selection before replying. A launch-time
            // notification can arrive before SwiftUI installs its subscriber.
            ChiefHomeNavigation(
                sidebarSelectionState: context.sidebarSelectionState,
                tabManager: tabManager
            ).open()
            if Self.socketCommandAllowsInAppFocusMutations() {
                _ = app.focusMainWindow(windowId: windowID)
            }
            self.scheduleSocketReadSnapshotRefresh()
            return .some(windowID)
        }
        // Chief's custom handler bypasses the normal mutation coordinator.
        // Publish its selection before a subsequent list/current read can
        // consult the worker's immutable mirror.
        if let publication = try await v2MainAsync({ self.socketReadSnapshotRefreshTask }) {
            await publication.value
        }
        switch windowID {
        case .none:
            return .err(code: "not_found",
                        message: String(localized: "socket.chief.error.windowNotFound", defaultValue: "No window matches that id."),
                        data: ["window_id": target.windowID ?? ""])
        case .some(.none):
            return .err(code: "not_found",
                        message: String(localized: "socket.chief.error.noWindow", defaultValue: "No cmux window is open."),
                        data: nil)
        case .some(.some(let id)):
            return .ok(["window_id": id.uuidString, "opened": true] as [String: Any])
        }
    }

#if DEBUG
    /// `chief.debug` (DEBUG builds only): the transcript's `debug*` helpers
    /// for automation. Reads and drives the shown transcript of
    /// `conversation`; never changes focus or window order.
    private nonisolated func chiefDebug(_ action: ChiefControlDebugAction, conversation: String?) async throws -> V2CallResult {
        let outcome: JSONValue? = try await v2MainAsync { () -> JSONValue? in
            guard let host = ChiefService.shared.controlVisibleHost(conversation: conversation),
                  let view = ChiefService.shared.controlVisibleTranscript(conversation: conversation) else { return nil }
            let payload: [String: Any]
            switch action {
            case .openSettings:
                payload = ["ok": true, "open": host.debugSetSettings(open: true)]
            case .closeSettings:
                payload = ["ok": true, "open": host.debugSetSettings(open: false)]
            case .openMemory:
                // As Settings' Show All: a sheet on the transcript's window. Only when none is
                // open: presenting again would order the open sheet front.
                if !ChiefMemoryEditor.isShown { ChiefMemoryEditor.present(selecting: .notes, in: host.window) }
                payload = ["ok": ChiefMemoryEditor.isShown, "open": ChiefMemoryEditor.isShown]
            case .closeMemory:
                ChiefMemoryEditor.dismiss()
                payload = ["ok": !ChiefMemoryEditor.isShown, "open": ChiefMemoryEditor.isShown]
            case .expandTools:
                payload = ["ok": host.debugExpandNewestToolRun()]
            case .tapback(let mine):
                payload = ["ok": view.debugTapbackNewestIncoming(mine: mine)]
            case .geometry:
                payload = ["geometry": view.debugGeometry()]
            case .rows:
                payload = ["rows": view.debugRowFrames().map { row -> [String: Any] in
                    ["kind": row.kind, "key": row.key, "outgoing": row.outgoing,
                     "frame": Self.chiefRect(row.frame), "balloon": Self.chiefRect(row.balloon)]
                }]
            case .messages(let limit):
                payload = ["texts": view.debugMessageTexts(limit: limit)]
            case .scroll(let dy):
                view.debugScroll(by: CGFloat(dy))
                payload = ["ok": true, "geometry": view.debugGeometry()]
            case .setDraft(let text):
                view.setDraft(text)
                payload = ["ok": true, "draft": view.draftText]
            case .sendDraft:
                let refusal = view.sendDraft()
                var result: [String: Any] = ["ok": refusal == nil]
                if let refusal { result["refusal"] = refusal }
                payload = result
            case .theme:
                let theme = ChiefTheme.current()
                payload = ["dark": theme.isDark,
                           "background": Self.chiefHex(theme.background),
                           "opaque_background": Self.chiefHex(theme.opaqueBackground),
                           "foreground": Self.chiefHex(theme.foreground),
                           "accent": Self.chiefHex(ChiefTheme.messagesBlue)]
            }
            return JSONValue(foundationObject: payload)
        }
        guard let outcome else {
            return .err(code: "not_found",
                        message: String(localized: "socket.chief.error.transcriptNotShown",
                                        defaultValue: "No window shows that Chief conversation."),
                        data: nil)
        }
        return .ok(outcome.foundationObject)
    }

    private nonisolated static func chiefRect(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.origin.x), "y": Double(rect.origin.y), "width": Double(rect.width), "height": Double(rect.height)]
    }

    private nonisolated static func chiefHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent),
                      byte(c.alphaComponent))
    }
#endif

    // MARK: - Helpers

    /// The owner, awaited off the main actor: only starting the service hops
    /// there; a load still running is awaited on the socket task.
    private nonisolated func chiefOwner() async throws -> ChiefConversationOwner {
        let load = try await v2MainAsync { ChiefService.shared.controlOwnerLoad() }
        do {
            return try await load.task.value
        } catch let failure as ChiefControlFailure {
            throw failure
        } catch {
            throw ChiefControlFailure.unavailable(load.failure)
        }
    }

    private static func chiefSendAsUser(text: String, conversation: String?) async throws -> ChiefControlSendResult {
        try await ChiefService.shared.controlSendAsUser(text: text, conversation: conversation)
    }

    /// Runs an owner call; a ``HomeRejection`` becomes a socket error.
    private nonisolated static func chiefOwnerCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let rejection as HomeRejection {
            throw ChiefControlFailure.from(rejection)
        }
    }

    /// Why `chief.answer`'s words do not answer the card.
    private nonisolated static func chiefAnswerProblemMessage(_ problem: ChiefQuestionAnswer.Problem) -> String {
        switch problem {
        case .unknownChoice(let choice):
            String(format: String(localized: "socket.chief.error.unknownQuestionChoice",
                                  defaultValue: "The question has no option named %@."), choice)
        case .otherNotAllowed:
            String(localized: "socket.chief.error.questionTakesNoText", defaultValue: "The question takes no typed answer.")
        case .invalid:
            String(localized: "socket.chief.error.incompleteAnswer",
                   defaultValue: "Those choices don't answer every part of the question.")
        }
    }

    private nonisolated static var chiefUnknownMethod: V2CallResult {
        .err(code: "method_not_found",
             message: String(localized: "socket.error.unknownMethod", defaultValue: "Unknown method"),
             data: nil)
    }

    private nonisolated static func chiefTime(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private nonisolated static func chiefPayload(_ status: ChiefControlStatus) -> [String: Any] {
        var payload: [String: Any] = [
            "started": status.started,
            "harness": status.harness,
            "harness_name": status.harnessName,
            "model": status.model,
            "effort": status.effort,
            "unread": status.unread,
            "conversation_count": status.conversationCount,
            "working": status.working,
            "default_conversation": status.defaultConversation,
        ]
        payload["home"] = status.home ?? NSNull()
        if let failure = status.startFailure { payload["start_failure"] = failure }
        return payload
    }

    private nonisolated static func chiefPayload(_ row: ChiefControlConversation) -> [String: Any] {
        ["id": row.id, "title": row.title, "preview": row.preview, "unread": row.unread, "pinned": row.pinned,
         "working": row.working, "updated_at": chiefTime(row.updatedAt)]
    }

    private nonisolated static func chiefPayload(_ message: ChiefControlMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "id": message.id, "seq": message.seq, "author": message.author, "author_id": message.authorID,
            "author_kind": message.authorKind, "text": message.text, "at": chiefTime(message.at), "parts": message.parts,
        ]
        if let root = message.threadRoot { payload["thread_root"] = root }
        return payload
    }
}
