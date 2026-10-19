import CMUXAgentLaunch
import CmuxAgentChat
import CmuxMobileHost
import CmuxControlSocket
import CmuxTerminal
import Bonsplit
import Foundation

/// `mobile.chat.*` RPC handlers: the Mac side of the iOS agent chat
/// surface. Session/transcript state lives in
/// ``AgentChatTranscriptService``; the send/interrupt/answer paths reuse
/// the existing mobile terminal injection machinery so chat input behaves
/// exactly like composer input.
extension TerminalController {
    /// Advances both classic Feed attention and mobile agent-chat state from
    /// the shared accepted-terminal-input seam.
    @MainActor
    func noteAcceptedAgentInput(surfaceID: UUID, at: Date = Date()) {
        _ = agentChatTranscriptService?.noteExplicitInput(
            surfaceID: surfaceID.uuidString,
            at: at
        )
        FeedCoordinator.shared.noteExplicitInput(surfaceID: surfaceID, at: at)
    }

    /// Actionable error for a chat session whose terminal binding cannot
    /// be resolved even after a hook-store refresh. Surfaces verbatim in the
    /// iOS chat error banner, so it is localized.
    static var chatTerminalBindingErrorMessage: String {
        String(
            localized: "mobile.chat.error.terminalMoved",
            defaultValue: "The agent's terminal moved. Open it once on your Mac (or send the agent any prompt there), then retry."
        )
    }

    /// Error shown when the Mac-side chat service is not wired into this
    /// process. Surfaces in mobile RPC error banners and debug responses.
    static var chatServiceUnavailableErrorMessage: String {
        String(
            localized: "mobile.chat.error.serviceUnavailable",
            defaultValue: "Agent chat transcript service is not configured"
        )
    }

    /// Error shown when a client asks the host to change controls that cannot
    /// be translated into the already-running provider process.
    static var chatLiveControlsUnsupportedMessage: String {
        String(
            localized: "mobile.chat.error.liveControlsUnsupported",
            defaultValue: "Change the model, permissions, or other agent settings in the terminal."
        )
    }

    /// Routes one `mobile.chat.*` method to its handler (single dispatch
    /// case in `mobileHostHandleRPC` keeps the god-file growth flat).
    func v2MobileChatDispatch(
        method: String,
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        // Session ids are opaque provider identifiers. A scoped attach ticket
        // cannot be checked from the request's workspace fields because chat
        // requests intentionally carry only the session id. Resolve the
        // record and its authoritative terminal/workspace binding before any
        // read or mutation; the list path applies the same check per record.
        if method != "mobile.chat.sessions",
           let authorization = executionContext?.attachTicketAuthorization,
           let error = mobileChatTicketAuthorizationError(
               params: params,
               authorization: authorization
           ) {
            return error
        }
        switch method {
        case "mobile.chat.sessions":
            return await v2MobileChatSessions(
                params: params,
                ticketAuthorization: executionContext?.attachTicketAuthorization
            )
        case "mobile.chat.session":
            return v2MobileChatSession(params: params)
        case "mobile.chat.rename":
            return v2MobileChatRename(params: params)
        case "mobile.chat.delete":
            return v2MobileChatDelete(params: params)
        case "mobile.chat.export":
            return await v2MobileChatExport(params: params)
        case "mobile.chat.fork":
            return await v2MobileChatLaunchSession(
                params: params,
                action: .fork
            )
        case "mobile.chat.resume":
            return await v2MobileChatLaunchSession(
                params: params,
                action: .resume
            )
        case "mobile.chat.reopen":
            return await v2MobileChatLaunchSession(
                params: params,
                action: .reopen
            )
        case "mobile.chat.history":
            return await v2MobileChatHistory(params: params)
        case "mobile.chat.controls":
            return await v2MobileChatControls(params: params)
        case "mobile.chat.controls.update":
            return await v2MobileChatControlsUpdate(params: params)
        case "mobile.chat.send":
            return await v2MobileChatSend(params: params)
        case "mobile.chat.interrupt":
            return await v2MobileChatInterrupt(params: params)
        case "mobile.chat.answer":
            return await v2MobileChatAnswer(params: params)
        case "mobile.chat.review":
            return await v2MobileChatReview(params: params)
        case "mobile.chat.artifact.stat":
            return await v2MobileChatArtifactStat(params: params)
        case "mobile.chat.artifact.fetch":
            return await v2MobileChatArtifactFetch(
                params: params,
                executionContext: executionContext
            )
        case "mobile.chat.artifact.thumbnail":
            return await v2MobileChatArtifactThumbnail(params: params)
        case "mobile.chat.artifact.list":
            return await v2MobileChatArtifactList(params: params)
        case "mobile.chat.artifact.gallery":
            return await v2MobileChatArtifactGallery(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }

    /// Applies the attach-ticket scope to an opaque chat session id. The
    /// record's stored workspace id is only a fallback for ended sessions;
    /// live sessions must resolve their stable surface id into the workspace
    /// that currently owns that terminal. This prevents a stale pre-relaunch
    /// workspace id, or a surface reused by another workspace, from widening
    /// a scoped ticket's read or mutation access.
    private func mobileChatTicketAuthorizationError(
        params: [String: Any],
        authorization: MobileAttachTicketAuthorization
    ) -> V2CallResult? {
        guard let sessionID = v2RawString(params, "session_id"),
              !sessionID.isEmpty else {
            // Let the method body return its normal invalid-params response.
            return nil
        }
        guard let service = agentChatTranscriptService,
              let record = service.sessionRecord(sessionID: sessionID) else {
            // Do not turn an unknown/deleted id into an authorization oracle;
            // the method body returns the usual not-found result.
            return nil
        }
        guard mobileChatTicketAllows(record: record, authorization: authorization) else {
            return .err(
                code: MobileHostService.scopedTicketError.code,
                message: MobileHostService.scopedTicketError.message,
                data: ["session_id": sessionID]
            )
        }
        return nil
    }

    private func mobileChatTicketAllows(
        record: AgentChatSessionRecord,
        resolvedWorkspaceID: String? = nil,
        authorization: MobileAttachTicketAuthorization
    ) -> Bool {
        let currentWorkspaceID = resolvedWorkspaceID
            ?? mobileChatCurrentWorkspaceID(surfaceID: record.surfaceID)
            ?? (record.state == .ended ? record.workspaceID : nil)
        return MobileHostService.chatTicketScopeAllows(
            ticket: authorization,
            sessionWorkspaceID: currentWorkspaceID,
            sessionSurfaceID: record.surfaceID
        )
    }

    /// Resolves a stable terminal surface to its current cmux workspace,
    /// walking every main window because chat sessions are not tied to the
    /// caller's selected tab.
    private func mobileChatCurrentWorkspaceID(surfaceID: String?) -> String? {
        guard let surfaceID,
              let surfaceUUID = UUID(uuidString: surfaceID),
              let app = AppDelegate.shared else {
            return nil
        }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else {
                continue
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.terminalInputTarget(forPanelID: surfaceUUID) != nil
            }) {
                return workspace.id.uuidString
            }
        }
        return nil
    }

    private static func chatTicketWorkspaceSelectionAllows(
        ticket: MobileAttachTicketAuthorization,
        workspaceID: String
    ) -> Bool {
        let requested = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticketWorkspace = ticket.ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return ticketWorkspace.isEmpty || requested == ticketWorkspace || ticket.createdWorkspaceIDs.contains(requested)
    }

    /// Returns the controls contract for a live session.
    ///
    /// Running provider processes are currently driven through terminal input,
    /// so cmux cannot truthfully claim that model, permission, sandbox, or plan
    /// changes would affect an in-flight turn. Keep the descriptor explicit
    /// about that limitation instead of exposing controls that only mutate
    /// cached session metadata.
    func v2MobileChatControls(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let service = agentChatTranscriptService,
              service.sessionRecord(sessionID: sessionID) != nil else {
            return .err(code: "not_found", message: "Unknown agent session", data: ["session_id": sessionID])
        }
        return .ok(Self.mobileChatControlsPayload(ChatSessionControls()))
    }

    /// Live provider controls are not supported while a session is running.
    /// Returning an error is important: acknowledging a metadata-only write
    /// would make the phone believe a later prompt uses values the provider
    /// process never received.
    func v2MobileChatControlsUpdate(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let service = agentChatTranscriptService,
              let record = service.sessionRecord(sessionID: sessionID) else {
            return .err(code: "not_found", message: "Unknown agent session", data: ["session_id": sessionID])
        }
        guard record.state != .ended else {
            return .err(code: "session_ended", message: "This agent session has ended and is read-only.", data: nil)
        }
        let allowedKeys = Set(["model_id", "reasoning_effort_id", "permission_mode", "sandbox_mode", "plan_mode"])
        guard params.keys.contains(where: allowedKeys.contains) else {
            return .err(code: "invalid_params", message: "No controls supplied", data: nil)
        }
        return .err(
            code: "unsupported",
            message: Self.chatLiveControlsUnsupportedMessage,
            data: ["session_id": sessionID]
        )
    }

    private static func mobileChatControlsPayload(_ controls: ChatSessionControls) -> [String: Any] {
        func options(_ values: [ChatSessionControlOption]) -> [[String: Any]] {
            values.map { value in
                var payload: [String: Any] = ["id": value.id, "display_name": value.displayName]
                if let description = value.description { payload["description"] = description }
                return payload
            }
        }
        var payload: [String: Any] = [
            "plan_mode": controls.planMode,
            "supports_plan_mode": controls.supportsPlanMode,
            "model_options": options(controls.modelOptions),
            "reasoning_effort_options": options(controls.reasoningEffortOptions),
            "permission_options": options(controls.permissionOptions),
            "sandbox_options": options(controls.sandboxOptions),
        ]
        if let value = controls.modelID { payload["model_id"] = value }
        if let value = controls.reasoningEffortID { payload["reasoning_effort_id"] = value }
        if let value = controls.permissionMode { payload["permission_mode"] = value }
        if let value = controls.sandboxMode { payload["sandbox_mode"] = value }
        return ["controls": payload]
    }

    /// `chat.sessions.dump` (local debug socket, main-actor lane): the
    /// full chat-session registry state, for diagnosing inconsistent
    /// phone-side states.
    func v2ChatSessionsDump() -> V2CallResult {
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        return .ok(["sessions": service.debugSessionDump()])
    }

    /// `mobile.chat.sessions`: list chat-capable coding-agent sessions,
    /// optionally scoped to one workspace.
    ///
    /// When a `workspace_id` W is given, sessions are scoped by the SURFACE'S
    /// CURRENT workspace, never the record's stored `workspaceID`. cmux
    /// workspace ids regenerate on every Mac relaunch while surface ids are
    /// stable, so a session created before the last relaunch carries a stale
    /// stored `workspaceID` and would otherwise be dropped from its terminal's
    /// current workspace. We resolve W once, collect W's live terminal surface
    /// ids once, then return every session whose surface is one of them and that
    /// still matches its agent against THAT workspace+panel. Each returned
    /// session is re-stamped to W so its seed and live `descriptorChanged`
    /// pushes both scope to the current workspace.
    func v2MobileChatSessions(
        params: [String: Any],
        ticketAuthorization: MobileAttachTicketAuthorization? = nil
    ) async -> V2CallResult {
        let workspaceID = v2String(params, "workspace_id")
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        if let ticketAuthorization,
           let workspaceID,
           !Self.chatTicketWorkspaceSelectionAllows(
               ticket: ticketAuthorization,
               workspaceID: workspaceID
           ) {
            return .err(
                code: "forbidden",
                message: MobileHostService.scopedTicketError.message,
                data: ["workspace_id": workspaceID]
            )
        }
        guard let workspaceID else {
            let observedBeforeListing = await service.observeAgentProcessesForListing(
                surfaceIDs: nil,
                waitUpTo: .milliseconds(750)
            )
            #if DEBUG
            if !observedBeforeListing {
                cmuxDebugLog("agentChat.list observeTimedOut workspace=nil")
            }
            #endif
            let descriptors = service.sessionRecords(workspaceID: nil)
                .filter { record in
                    guard let ticketAuthorization else { return true }
                    return mobileChatTicketAllows(
                        record: record,
                        authorization: ticketAuthorization
                    )
                }
                .filter { record in
                    // A finished session is a historical conversation. Its
                    // agent PID is expected to be dead, so the live binding
                    // check would incorrectly hide it from Agent history.
                    // Keep it listable when the transcript resolver says it
                    // can still be opened read-only; live sessions still
                    // require the terminal to be bound to the same agent.
                    if record.state == .ended {
                        return service.shouldListEndedSession(record)
                    }
                    return mobileChatBindingIsCurrentAgent(record)
                }
                .map(\.descriptor)
            let encoded = descriptors.compactMap { service.wirePayload($0) }
            #if DEBUG
            cmuxDebugLog("agentChat.list workspace=nil records=\(service.sessionRecords(workspaceID: nil).count) returned=\(encoded.count)")
            #endif
            return .ok(["sessions": encoded])
        }
        // Resolve W to its live Workspace once; build the set of its live
        // terminal surface ids once, then filter sessions against that set.
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: ["workspace_id": workspaceID],
            requireTerminal: false
        ) else {
            #if DEBUG
            cmuxDebugLog("agentChat.list workspace=\(workspaceID.prefix(8)) RESOLVE_FAILED returned=0")
            #endif
            return .ok(["sessions": []])
        }
        let workspace = resolved.workspace
        let terminalSurfaceIDs = Set(mobileTerminalPanels(in: workspace).map(\.id))
        // Workspace GUI pulls force a scoped scan and wait only to a local deadline.
        let observedBeforeListing = await service.observeAgentProcessesForListing(
            surfaceIDs: terminalSurfaceIDs,
            waitUpTo: .milliseconds(750)
        )
        #if DEBUG
        if !observedBeforeListing {
            cmuxDebugLog("agentChat.list observeTimedOut workspace=\(workspaceID.prefix(8))")
        }
        #endif
        var encoded: [[String: Any]] = []
        #if DEBUG
        var dropNotInWorkspace = 0, dropDeadPID = 0, dropEndedMissingTranscript = 0, kept = 0
        let allRecords = service.sessionRecords(workspaceID: nil)
        #endif
        for record in service.sessionRecords(workspaceID: nil) {
            guard let surfaceID = record.surfaceID,
                  let surfaceUUID = UUID(uuidString: surfaceID),
                  workspace.terminalInputTarget(forPanelID: surfaceUUID) != nil else {
                #if DEBUG
                dropNotInWorkspace += 1
                #endif
                continue
            }
            if let ticketAuthorization,
               !mobileChatTicketAllows(
                   record: record,
                   resolvedWorkspaceID: workspaceID,
                   authorization: ticketAuthorization
               ) {
                #if DEBUG
                dropNotInWorkspace += 1
                #endif
                continue
            }
            // Live sessions must match the terminal's current agent. Ended
            // sessions stay visible read-only while their surface is still in W.
            if record.state != .ended,
               !mobileChatRecordMatchesAgent(record: record) {
                #if DEBUG
                dropDeadPID += 1
                cmuxDebugLog("agentChat.list drop=deadPID session=\(record.sessionID.prefix(8)) kind=\(record.agentKind.sourceName) surface=\(record.surfaceID?.prefix(8) ?? "nil") pid=\(record.pid.map(String.init) ?? "nil")")
                #endif
                continue
            }
            if record.state == .ended,
               !service.shouldListEndedSession(record) {
                #if DEBUG
                dropEndedMissingTranscript += 1
                cmuxDebugLog("agentChat.list drop=endedMissingTranscript session=\(record.sessionID.prefix(8)) kind=\(record.agentKind.sourceName) surface=\(record.surfaceID?.prefix(8) ?? "nil")")
                #endif
                continue
            }
            #if DEBUG
            kept += 1
            #endif
            // Re-stamp stale-workspace records so seeds and pushes scope to W.
            if record.workspaceID != workspaceID {
                service.updateSessionWorkspace(sessionID: record.sessionID, workspaceID: workspaceID)
            }
            let descriptor = service.sessionRecord(sessionID: record.sessionID)?.descriptor ?? record.descriptor
            if let payload = service.wirePayload(descriptor) {
                encoded.append(payload)
            }
        }
        #if DEBUG
        cmuxDebugLog("agentChat.list workspace=\(workspaceID.prefix(8)) total=\(allRecords.count) dropNotInWS=\(dropNotInWorkspace) dropDeadPID=\(dropDeadPID) dropEndedMissingTranscript=\(dropEndedMissingTranscript) kept=\(kept) returned=\(encoded.count)")
        #endif
        return .ok(["sessions": encoded])
    }

    /// `mobile.chat.session`: authoritative snapshot of one session by id.
    ///
    /// The client's pull path: on (re)connect, foreground, a detected version
    /// gap, or manual refresh, the phone fetches the current descriptor (with
    /// its monotonic `version`) and reconciles wholesale, so a missed or
    /// out-of-order best-effort push self-heals. `not_found` means the session
    /// is unknown to the host (e.g. cleared); the client drops it.
    func v2MobileChatSession(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2String(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "session_id required", data: nil)
        }
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        guard let record = service.sessionRecord(sessionID: sessionID),
              let encoded = service.wirePayload(record.descriptor) else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "mobile.chat.error.sessionNotFound",
                    defaultValue: "That agent session is no longer available."
                ),
                data: ["session_id": sessionID]
            )
        }
        return .ok(["session": encoded])
    }

    /// `mobile.chat.rename`: update the host-owned conversation title.
    func v2MobileChatRename(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty,
              let title = v2RawString(params, "title") else {
            return .err(code: "invalid_params", message: "session_id and title required", data: nil)
        }
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        guard service.renameSession(sessionID: sessionID, title: title) else {
            return .err(code: "not_found", message: "That agent session is no longer available.", data: ["session_id": sessionID])
        }
        return .ok(["session_id": sessionID, "title": title.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// `mobile.chat.delete`: hide a conversation from the mobile history.
    func v2MobileChatDelete(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "session_id required", data: nil)
        }
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        guard service.deleteSession(sessionID: sessionID) else {
            return .err(code: "not_found", message: "That agent session is no longer available.", data: ["session_id": sessionID])
        }
        return .ok(["session_id": sessionID, "deleted": true])
    }

    /// `mobile.chat.export`: return a Markdown document assembled from the
    /// authoritative transcript pages.
    func v2MobileChatExport(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "session_id required", data: nil)
        }
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        guard let text = await service.exportTranscript(sessionID: sessionID) else {
            return .err(code: "not_found", message: "That agent transcript is no longer available.", data: ["session_id": sessionID])
        }
        return .ok(["session_id": sessionID, "text": text, "format": "markdown"])
    }

    /// `mobile.chat.fork` / `mobile.chat.resume` / `mobile.chat.reopen`:
    /// materialize a provider-native session in a new sibling terminal. The
    /// terminal is deliberately created without focus so a phone action never
    /// steals the user's current Mac selection. Provider hooks may publish the
    /// resulting child session after this method returns; the terminal id in
    /// the acknowledgement lets the phone select it once that descriptor
    /// arrives.
    func v2MobileChatLaunchSession(
        params: [String: Any],
        action: ChatSessionLaunchResult.Action
    ) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "session_id required", data: nil)
        }
        guard let service = agentChatTranscriptService,
              var record = service.sessionRecord(sessionID: sessionID) else {
            return .err(code: "not_found", message: "That agent session is no longer available.", data: [
                "session_id": sessionID
            ])
        }

        // A completed session can be resumed even though its process is gone.
        // Refresh only the terminal/transcript bindings; this keeps ended
        // history usable after a workspace relaunch without reopening a stale
        // process binding.
        if let refreshed = await service.refreshSessionBindings(sessionID: sessionID) {
            record = refreshed
        }
        guard let workspaceID = mobileChatCurrentWorkspaceID(surfaceID: record.surfaceID)
            ?? record.workspaceID else {
            return .err(
                code: "not_found",
                message: Self.chatTerminalBindingErrorMessage,
                data: ["session_id": sessionID]
            )
        }
        let workspace: Workspace
        let paneID: PaneID
        if let surfaceID = record.surfaceID,
           UUID(uuidString: surfaceID) != nil,
           let resolved = mobileResolveWorkspaceAndSurface(
               params: ["workspace_id": workspaceID, "surface_id": surfaceID],
               requireTerminal: true
           ),
           let resolvedSurfaceID = resolved.surfaceId,
           let sourcePaneID = resolved.workspace.paneId(forPanelId: resolvedSurfaceID) {
            workspace = resolved.workspace
            paneID = sourcePaneID
        } else if action != .fork,
                  let resolved = mobileResolveWorkspaceAndSurface(
                      params: ["workspace_id": workspaceID],
                      requireTerminal: false
                  ),
                  let anchorPanelID = resolved.workspace.focusedTerminalInputTarget()?.panel.id
                      ?? mobileTerminalPanels(in: resolved.workspace).first?.id,
                  let fallbackPaneID = resolved.workspace.paneId(forPanelId: anchorPanelID) {
            // A durable ended session can outlive its original terminal. Use
            // any surviving terminal in the recorded workspace as the anchor
            // for Resume/Reopen; Fork still requires its source terminal.
            workspace = resolved.workspace
            paneID = fallbackPaneID
        } else {
            return .err(
                code: "not_found",
                message: Self.chatTerminalBindingErrorMessage,
                data: ["session_id": sessionID]
            )
        }

        guard let kind = RestorableAgentKind(rawValue: record.agentKind.sourceName) else {
            return .err(
                code: "unsupported",
                message: "This agent does not support reopening from mobile.",
                data: ["session_id": sessionID, "agent_kind": record.agentKind.sourceName]
            )
        }
        let snapshot = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: record.workingDirectory
        )
        let initialInput: String?
        switch action {
        case .fork:
            initialInput = snapshot.forkStartupInput()
        case .resume, .reopen:
            initialInput = snapshot.resumeStartupInput(useLocalRestoreVerb: false)
        }
        guard let initialInput else {
            return .err(
                code: "unsupported",
                message: "This agent does not support reopening from mobile.",
                data: ["session_id": sessionID, "agent_kind": record.agentKind.sourceName]
            )
        }

        let panel = workspace.newTerminalSurface(
            inPane: paneID,
            focus: false,
            workingDirectory: record.workingDirectory,
            initialInput: initialInput,
            startupRestoreAgent: action == .fork ? snapshot : nil,
            preserveFocusWhenUnfocused: true
        )
        guard let panel else {
            return .err(
                code: "internal_error",
                message: "The Mac could not create a terminal for this session.",
                data: ["session_id": sessionID]
            )
        }
        var payload: [String: Any] = [
            "action": action.rawValue,
            "parent_session_id": sessionID,
            "terminal_id": panel.id.uuidString,
        ]
        payload["workspace_id"] = workspace.id.uuidString
        if let workingDirectory = record.workingDirectory {
            payload["cwd"] = workingDirectory
        }
        return .ok(payload)
    }

    /// `mobile.chat.history`: one transcript page for a session.
    func v2MobileChatHistory(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let limit = min(max(v2Int(params, "limit") ?? 100, 1), 200)
        let beforeSeq = v2Int(params, "before_seq")
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        var page = await service.history(sessionID: sessionID, beforeSeq: beforeSeq, limit: limit)
        if page == nil, let staleRecord = service.sessionRecord(sessionID: sessionID) {
            // The record exists but its transcript didn't resolve — the
            // recorded path can be stale the same way terminal bindings
            // are. Re-adopt from the hook store and retry once, but only
            // when the refresh actually changed the resolution inputs (a
            // pointless retry re-runs the codex directory walk).
            #if DEBUG
            cmuxDebugLog("mobile.chat.history transcript unresolved session=\(sessionID.prefix(8)); refreshing bindings")
            #endif
            let refreshed = await service.refreshSessionBindings(sessionID: sessionID)
            if refreshed?.transcriptPath != staleRecord.transcriptPath
                || refreshed?.workingDirectory != staleRecord.workingDirectory {
                page = await service.history(sessionID: sessionID, beforeSeq: beforeSeq, limit: limit)
            }
        }
        guard let page else {
            #if DEBUG
            cmuxDebugLog("mobile.chat.history not_found session=\(sessionID.prefix(8))")
            #endif
            return .err(code: "not_found", message: String(
                localized: "mobile.chat.error.transcriptNotReadable",
                defaultValue: "The Mac can't find a transcript file for this conversation. If the agent just started in a project folder, send it a prompt and tap Retry. If it's running in your home directory, it doesn't keep a transcript, so use the Terminal tab to interact."
            ), data: [
                "session_id": sessionID
            ])
        }
        guard let payload = service.wirePayload(page) else {
            return .err(code: "internal_error", message: "History encoding failed", data: nil)
        }
        return .ok(payload)
    }

    /// `mobile.chat.send`: deliver attachments then inject the prompt into
    /// the session's terminal (bracketed paste + submit key).
    func v2MobileChatSend(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        if let mutationError = mobileChatMutationError(sessionID: sessionID) {
            return mutationError
        }
        guard !params.keys.contains("controls") else {
            return .err(
                code: "unsupported",
                message: Self.chatLiveControlsUnsupportedMessage,
                data: ["session_id": sessionID]
            )
        }
        return await v2MobileChatSendValidated(params: params, sessionID: sessionID)
    }

    private func v2MobileChatSendValidated(params: [String: Any], sessionID: String) async -> V2CallResult {
        let text = v2RawString(params, "text") ?? ""
        let attachments = params["attachments"] as? [[String: Any]] ?? []
        guard !text.isEmpty || !attachments.isEmpty else {
            return .err(code: "invalid_params", message: "Nothing to send", data: nil)
        }
        // Validate the entire attachment batch before clearing the terminal's
        // prompt. A malformed item must leave the user's draft untouched so
        // they can correct or retry it after the error response.
        if let attachmentError = Self.chatAttachmentValidationError(attachments) {
            return attachmentError
        }
        guard let terminalParams = await mobileChatTerminalParams(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        guard let terminalTarget = await mobileChatTerminalTarget(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let clearResult = clearAgentPrompt(terminalTarget)
        guard clearResult.accepted else {
            return mobileChatInputError(clearResult)
        }
        for (index, attachment) in attachments.enumerated() {
            let kind = (attachment["kind"] as? String) ?? "image"
            switch kind {
            case "file":
                guard let path = attachment["path"] as? String,
                      path.hasPrefix("/"),
                      !path.contains("\0"),
                      Self.chatAttachmentPathIsOwned(path) else {
                    return .err(code: "invalid_params", message: "File attachment missing an absolute path", data: nil)
                }
                let sendResult = terminalTarget.sendInputResult(Self.chatShellWord(path))
                switch sendResult {
                case .sent:
                    terminalTarget.forceRefresh(reason: "mobileHost.chatFileAttachment")
                case .queued:
                    break
                case .inputQueueFull:
                    return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: nil)
                case .surfaceUnavailable:
                    return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
                case .processExited:
                    return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: nil)
                }
            default:
                guard let base64 = attachment["data_b64"] as? String else {
                    return .err(code: "invalid_params", message: "Attachment missing data_b64", data: nil)
                }
                var imageParams = terminalParams
                imageParams["image_base64"] = base64
                imageParams["image_format"] = (attachment["format"] as? String) ?? "png"
                let result = v2MobileTerminalPasteImage(params: imageParams)
                if case .err = result {
                    return result
                }
            }
            // Separate each pasted path from the next path or the prompt
            // (the local Mac paste joins with spaces too) so the agent
            // detects the paths and the echo is "<path> <path> <text>" —
            // the shape the client's pending-row reconcile matches. A
            // dropped separator corrupts that shape; surface it.
            let needsSeparator = index < attachments.count - 1 || !text.isEmpty
            if needsSeparator {
                guard let currentTarget = mobileCanonicalTerminalTarget(params: terminalParams)?.target else {
                    return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                        "session_id": sessionID
                    ])
                }
                let separatorResult = currentTarget.sendInputResult(" ")
                switch separatorResult {
                case .sent, .queued:
                    break
                case .inputQueueFull:
                    return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: nil)
                case .surfaceUnavailable:
                    return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
                case .processExited:
                    return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: nil)
                }
            }
        }
        guard !text.isEmpty else {
            // Attachment-only send: the image path is sitting pasted at the
            // agent's prompt; submit it so the send actually reaches the
            // agent instead of idling in the line editor.
            guard let currentTarget = mobileCanonicalTerminalTarget(params: terminalParams)?.target else {
                return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                    "session_id": sessionID
                ])
            }
            let keyResult = currentTarget.sendNamedKeyResult("return")
            return .ok(["submitted": keyResult.accepted])
        }
        var pasteParams = terminalParams
        pasteParams["text"] = text
        return await v2MobileTerminalPaste(params: pasteParams)
    }

    /// Quotes a host materialized attachment path before it enters the agent's
    /// shell-backed terminal. The upload store already restricts paths to its
    /// own absolute directory; quoting also keeps spaces and shell metacharacters
    /// inside the attachment reference.
    private static func chatShellWord(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%=")
        guard !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) else {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return path
    }

    private static func chatAttachmentValidationError(
        _ attachments: [[String: Any]]
    ) -> V2CallResult? {
        for attachment in attachments {
            let kind = (attachment["kind"] as? String) ?? "image"
            switch kind {
            case "file":
                guard let path = attachment["path"] as? String,
                      path.hasPrefix("/"),
                      !path.contains("\0"),
                      chatAttachmentPathIsOwned(path) else {
                    return .err(code: "invalid_params", message: "File attachment missing an absolute path", data: nil)
                }
            default:
                guard let base64 = attachment["data_b64"] as? String,
                      let data = Data(base64Encoded: base64),
                      !data.isEmpty else {
                    return .err(code: "invalid_params", message: "Missing or invalid image_base64", data: nil)
                }
            }
        }
        return nil
    }

    private static func chatAttachmentPathIsOwned(_ path: String) -> Bool {
        let root = MobileTaskAttachmentStore.defaultRootURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// `mobile.chat.interrupt`: polite (Esc) or hard (ctrl-C) interrupt of
    /// the session's agent.
    func v2MobileChatInterrupt(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        if let mutationError = mobileChatMutationError(sessionID: sessionID) {
            return mutationError
        }
        let hard = (params["hard"] as? Bool) ?? false
        guard let terminalTarget = await mobileChatTerminalTarget(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let keyResult = terminalTarget.sendNamedKeyResult(hard ? "ctrl+c" : "escape")
        guard keyResult.accepted else {
            return .err(code: "surface_unavailable", message: String(
                localized: "mobile.chat.error.interruptNotAccepted",
                defaultValue: "Interrupt key was not accepted"
            ), data: nil)
        }
        terminalTarget.forceRefresh(reason: "mobileHost.chatInterrupt")
        return .ok(["interrupted": true, "hard": hard])
    }

    /// `mobile.chat.answer`: answer an in-terminal choice by display index
    /// (agent TUIs accept the option's number key).
    func v2MobileChatAnswer(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let optionIndexes = (params["option_indexes"] as? [Any])?.compactMap { raw -> Int? in
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            return nil
        } ?? []
        let optionIndex = v2Int(params, "option_index")
        let text = v2RawString(params, "text")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !optionIndexes.isEmpty || (optionIndex != nil && optionIndex! >= 0) || !(text?.isEmpty ?? true) else {
            return .err(code: "invalid_params", message: "Missing answer", data: nil)
        }
        let requestID = v2RawString(params, "request_id")
        let selectedIndexes = (text?.isEmpty == false)
            ? []
            : (optionIndexes.isEmpty ? [optionIndex ?? -1] : optionIndexes)
        let service = agentChatTranscriptService
        let record = service?.sessionRecord(sessionID: sessionID)
        if let mutationError = mobileChatMutationError(sessionID: sessionID) {
            return mutationError
        }
        if let service,
           let requestID,
           (record?.agentKind == .claude || record?.agentKind == .other("opencode")),
           let answer = service.feedAnswer(
               sessionID: sessionID,
               messageID: requestID,
               optionIndexes: selectedIndexes,
               text: text
           ) {
            // Claude and OpenCode wait inside feed.push. Waking that waiter is
            // the authoritative answer path; these agents do not need a
            // terminal digit injection to accept the decision. The service
            // also resolves the exact synthetic card before returning.
            if let decision = answer.decision {
                FeedCoordinator.shared.deliverReply(
                    requestId: answer.requestID,
                    decision: decision
                )
            }
            if let surfaceID = record?.surfaceID {
                service.noteExplicitInput(surfaceID: surfaceID)
            }
            var response: [String: Any] = ["answered": true]
            if !selectedIndexes.isEmpty { response["option_indexes"] = selectedIndexes }
            if let text, !text.isEmpty { response["text"] = text }
            return .ok(response)
        }
        if let service,
           let requestID,
           (record?.agentKind == .claude || record?.agentKind == .other("opencode")),
           let text, !text.isEmpty,
           let resolved = service.resolvedQuestionText(
               sessionID: sessionID,
               messageID: requestID,
               text: text
           ) {
            if resolved {
                return .ok(["answered": true, "text": text, "idempotent": true])
            }
            return .err(
                code: "conflicting_answer",
                message: "That question was already answered with different text.",
                data: ["session_id": sessionID, "request_id": requestID]
            )
        }
        if let service,
           let requestID,
           (record?.agentKind == .claude || record?.agentKind == .other("opencode")),
           let optionIndex,
           let resolved = service.resolvedQuestionAnswer(
               sessionID: sessionID,
               messageID: requestID,
               optionIndex: optionIndex
           ) {
            if resolved {
                return .ok(["answered": true, "option_index": optionIndex, "idempotent": true])
            }
            return .err(
                code: "conflicting_answer",
                message: "That question was already answered with a different option.",
                data: ["session_id": sessionID, "request_id": requestID]
            )
        }
        // Codex's request_user_input picker also accepts a free-form answer.
        // It is terminal-owned rather than a feed.push waiter, so inject the
        // text and submit it through the same bound surface as its option key.
        if let text, !text.isEmpty {
            guard let terminalTarget = await mobileChatTerminalTarget(sessionID: sessionID) else {
                return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                    "session_id": sessionID
                ])
            }
            let sendResult = terminalTarget.sendInputResult(text + "\r")
            switch sendResult {
            case .sent, .queued:
                terminalTarget.forceRefresh(reason: "mobileHost.chatTextAnswer")
                if let surfaceID = record?.surfaceID {
                    service?.noteExplicitInput(surfaceID: surfaceID)
                }
                return .ok(["answered": true, "text": text])
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return .err(code: "surface_unavailable", message: String(
                    localized: "mobile.chat.error.answerNotAccepted",
                    defaultValue: "Answer was not accepted"
                ), data: nil)
            }
        }
        // Native terminal pickers accept single-digit option keys. Feed cards
        // are handled above and may expose more options, but never turn a
        // two-digit mobile index into ambiguous terminal input.
        let terminalOptionIndexes = optionIndexes.isEmpty
            ? (optionIndex.map { [$0] } ?? [])
            : optionIndexes
        guard !terminalOptionIndexes.isEmpty,
              terminalOptionIndexes.allSatisfy({ $0 >= 0 && $0 < 9 }) else {
            return .err(code: "invalid_params", message: "option_index is outside the terminal picker range", data: nil)
        }
        guard let terminalTarget = await mobileChatTerminalTarget(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        // Claude's picker submits on the digit alone; Codex's `request_user_input`
        // picker highlights on the digit and needs Enter to submit ("enter to
        // submit answer"), so append a carriage return for codex.
        let isCodex = record?.agentKind == .codex
        guard isCodex || terminalOptionIndexes.count == 1 else {
            return .err(code: "invalid_params", message: "Multiple options are supported only by the Codex picker", data: nil)
        }
        let digits = terminalOptionIndexes.map { String($0 + 1) }.joined()
        let answerKeys = isCodex ? "\(digits)\r" : digits
        let sendResult = terminalTarget.sendInputResult(answerKeys)
        switch sendResult {
        case .sent, .queued:
            terminalTarget.forceRefresh(reason: "mobileHost.chatAnswer")
            if let firstOptionIndex = terminalOptionIndexes.first {
                _ = service?.resolvePermission(
                    sessionID: sessionID,
                    requestID: requestID,
                    optionIndex: firstOptionIndex
                )
                if let requestID {
                    for optionIndex in terminalOptionIndexes {
                        _ = service?.resolveQuestion(
                            sessionID: sessionID,
                            messageID: requestID,
                            optionIndex: optionIndex
                        )
                    }
                }
            }
            if let surfaceID = record?.surfaceID {
                service?.noteExplicitInput(surfaceID: surfaceID)
            }
            return .ok(["answered": true, "option_indexes": terminalOptionIndexes])
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            return .err(code: "surface_unavailable", message: String(
                localized: "mobile.chat.error.answerNotAccepted",
                defaultValue: "Answer key was not accepted"
            ), data: nil)
        }
    }

    /// `mobile.chat.review`: apply or reverse a unified file edit, or send a
    /// line-scoped review comment back through the bound agent session.
    ///
    /// Apply/revert run in the session working directory and are deliberately
    /// host-owned rather than shell-injected. This keeps patch text out of a
    /// provider TUI and lets git reject malformed or out-of-tree paths.
    func v2MobileChatReview(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"),
              let action = v2RawString(params, "action"),
              let filePath = v2RawString(params, "file_path"),
              let messageID = v2RawString(params, "message_id") else {
            return .err(code: "invalid_params", message: "Missing review parameters", data: nil)
        }
        guard ["apply", "revert", "comment"].contains(action) else {
            return .err(code: "invalid_params", message: "Unknown review action", data: nil)
        }
        if let mutationError = mobileChatMutationError(sessionID: sessionID) {
            return mutationError
        }
        guard let record = agentChatTranscriptService?.sessionRecord(sessionID: sessionID),
              let workingDirectory = record.workingDirectory,
              let resolvedPath = Self.chatReviewPath(filePath, workingDirectory: workingDirectory) else {
            return .err(code: "invalid_params", message: "Review path is outside the session workspace", data: nil)
        }

        switch action {
        case "comment":
            guard let lineNumber = v2Int(params, "line_number"), lineNumber > 0,
                  let comment = v2RawString(params, "comment"),
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "Line comments require a positive line and comment", data: nil)
            }
            let prompt = "Review comment on \(resolvedPath.path):\(lineNumber)\n\(comment)"
            return await v2MobileChatSend(params: ["session_id": sessionID, "text": prompt])
        case "apply", "revert":
            guard let unifiedDiff = v2RawString(params, "unified_diff"),
                  !unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "Applying a review requires the unified diff", data: nil)
            }
            guard Self.chatReviewPatchMatchesPath(
                unifiedDiff,
                declaredPath: resolvedPath,
                workingDirectory: workingDirectory
            ) else {
                return .err(
                    code: "invalid_params",
                    message: "The unified diff does not match the reviewed file",
                    data: ["file_path": resolvedPath.path]
                )
            }
            let result = Self.runChatReviewGit(
                action: action,
                workingDirectory: workingDirectory,
                unifiedDiff: unifiedDiff
            )
            let applied = result.status == 0
                || Self.applyPresentationReviewFallback(
                    action: action,
                    fileURL: resolvedPath,
                    diff: unifiedDiff
                )
            guard applied else {
                return .err(code: "review_rejected", message: result.output.isEmpty ? "The patch could not be applied" : result.output, data: [
                    "session_id": sessionID,
                    "message_id": messageID,
                    "file_path": resolvedPath.path
                ])
            }
            return .ok([
                "reviewed": true,
                "action": action,
                "session_id": sessionID,
                "message_id": messageID,
                "file_path": resolvedPath.path
            ])
        default:
            return .err(code: "invalid_params", message: "Unknown review action", data: nil)
        }
    }

    nonisolated private static func chatReviewPath(_ path: String, workingDirectory: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        // Lexical normalization alone is insufficient here: a path such as
        // `Sources/link.swift` can point outside the workspace when `link`
        // is a symlink. Resolve existing path components before checking the
        // containment boundary, while preserving the final component when it
        // does not exist yet (create-file review patches).
        let root = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let lexicalCandidate = (path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: workingDirectory).appendingPathComponent(path))
            .standardizedFileURL
        let candidate = lexicalCandidate.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// Checks every path named by a unified diff against the file selected by
    /// the user. Git normally rejects `../` paths, but it can still mutate a
    /// different in-tree file when an untrusted patch's headers disagree with
    /// the card's declared path. `/dev/null` is allowed for create/delete
    /// patches; all other paths must resolve to the same file.
    nonisolated static func chatReviewPatchMatchesPath(
        _ unifiedDiff: String,
        declaredPath: URL,
        workingDirectory: String
    ) -> Bool {
        var paths: [String] = []
        for rawLine in unifiedDiff.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                let components = line.dropFirst("diff --git ".count).split(separator: " ", omittingEmptySubsequences: true)
                if components.count >= 2 {
                    paths.append(String(components[0]))
                    paths.append(String(components[1]))
                }
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                let path = line.dropFirst(4).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
                paths.append(String(path))
            }
        }
        // Claude transcript edits use a compact presentation diff with only
        // `-`/`+` lines. It is already bound to the selected card path by the
        // caller; the exact-content fallback performs the stale-content check.
        if paths.isEmpty {
            return unifiedDiff.split(whereSeparator: \.isNewline).allSatisfy {
                $0.first == "+" || $0.first == "-"
            }
        }
        return paths.allSatisfy { rawPath in
            guard rawPath != "/dev/null" else { return true }
            var path = rawPath
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path.removeFirst()
                path.removeLast()
            }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path.removeFirst(2)
            }
            guard let resolved = chatReviewPath(path, workingDirectory: workingDirectory) else {
                return false
            }
            return resolved.path == declaredPath.path
        }
    }

    private static func runChatReviewGit(
        action: String,
        workingDirectory: String,
        unifiedDiff: String
    ) -> (status: Int32, output: String) {
        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-review-\(UUID().uuidString).patch")
        do {
            try Data(unifiedDiff.utf8).write(to: patchURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: patchURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", workingDirectory, "apply", "--whitespace=nowarn"]
                + (action == "revert" ? ["--reverse"] : [])
                + [patchURL.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (1, error.localizedDescription)
        }
    }

    /// Applies transcript presentation diffs when they are not patch-grade.
    /// The replacement is exact and path-bound, so stale or ambiguous edits
    /// are rejected rather than silently mutating the wrong content.
    private static func applyPresentationReviewFallback(
        action: String,
        fileURL: URL,
        diff: String
    ) -> Bool {
        let lines = diff.components(separatedBy: "\n")
        guard !lines.isEmpty,
              lines.allSatisfy({ $0.first == "+" || $0.first == "-" }) else { return false }
        let oldLines = lines.compactMap { $0.first == "-" ? String($0.dropFirst()) : nil }
        let newLines = lines.compactMap { $0.first == "+" ? String($0.dropFirst()) : nil }
        let source: String
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            guard action == "apply", oldLines.isEmpty, !newLines.isEmpty else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(newLines.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
                return true
            } catch { return false }
        }
        let from = action == "apply" ? oldLines : newLines
        let to = action == "apply" ? newLines : oldLines
        if from.isEmpty {
            guard action == "apply" else { return false }
            do {
                try Data(to.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
                return true
            } catch { return false }
        }
        let sourceLines = source.components(separatedBy: "\n")
        guard sourceLines.count >= from.count else { return false }
        let matches = (0...(sourceLines.count - from.count)).filter { start in
            Array(sourceLines[start..<(start + from.count)]) == from
        }
        guard matches.count == 1 else { return false }
        var output = sourceLines
        let start = matches[0]
        output.replaceSubrange(start..<(start + from.count), with: to)
        do {
            try Data(output.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
            return true
        } catch { return false }
    }

    /// Ended sessions remain available for read-only history, but never accept
    /// new prompts or interactive decisions. Checking this before resolving a
    /// terminal also prevents a stale binding (especially one with no PID)
    /// from routing input into a reused surface.
    private func mobileChatMutationError(sessionID: String) -> V2CallResult? {
        guard let record = agentChatTranscriptService?.sessionRecord(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        guard record.state != .ended else {
            return .err(
                code: "session_ended",
                message: String(
                    localized: "mobile.chat.error.sessionEnded",
                    defaultValue: "This agent session has ended and is read-only."
                ),
                data: ["session_id": sessionID]
            )
        }
        return nil
    }

    /// Workspace/surface params for a chat session's bound terminal, in the
    /// shape the existing mobile terminal handlers expect.
    ///
    /// The session is bound to a specific terminal (its surface id). Surface
    /// ids are stable across relaunch/restore now, so the recorded surface
    /// keeps resolving; a still-stale binding is re-adopted once from the
    /// hook store (every hook event rewrites it with the current panel) and
    /// retried. If it still doesn't resolve we fail with an actionable error
    /// rather than redirect the prompt to some other terminal.
    private func mobileChatTerminalParams(sessionID: String) async -> [String: Any]? {
        guard let service = agentChatTranscriptService else { return nil }
        guard let record = service.sessionRecord(sessionID: sessionID),
              let workspaceID = record.workspaceID else {
            return nil
        }
        if let surfaceID = record.surfaceID,
           mobileChatBindingResolves(workspaceID: workspaceID, surfaceID: surfaceID),
           mobileChatBindingIsCurrentAgent(record) {
            return ["workspace_id": workspaceID, "surface_id": surfaceID]
        }
        #if DEBUG
        cmuxDebugLog("mobile.chat binding stale session=\(sessionID.prefix(8)) surface=\(record.surfaceID?.prefix(8) ?? "nil"); refreshing from hook store")
        #endif
        if let refreshed = await service.refreshSessionBindings(sessionID: sessionID),
           let surfaceID = refreshed.surfaceID,
           mobileChatBindingResolves(workspaceID: workspaceID, surfaceID: surfaceID),
           mobileChatBindingIsCurrentAgent(refreshed) {
            return ["workspace_id": workspaceID, "surface_id": surfaceID]
        }
        #if DEBUG
        cmuxDebugLog("mobile.chat binding unresolved session=\(sessionID.prefix(8))")
        #endif
        return nil
    }

    /// Whether a workspace/surface pair resolves to a live terminal panel.
    private func mobileChatBindingResolves(workspaceID: String, surfaceID: String) -> Bool {
        let params: [String: Any] = ["workspace_id": workspaceID, "surface_id": surfaceID]
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              resolved.workspace.controlSocketTerminalTarget(for: surfaceId) != nil else {
            return false
        }
        return true
    }

    /// Whether the record's bound terminal still appears to be the agent it
    /// represents. This prevents a stale registry surface id from exposing a
    /// chat toggle or routing prompts into a plain shell after a terminal was
    /// restored/reused.
    ///
    /// Resolves the terminal via the record's STORED `workspaceID`, which is
    /// the very value that goes stale after a Mac relaunch — so use this only
    /// for the no-filter path. The workspace-filtered path
    /// (``v2MobileChatSessions``) resolves the surface to its CURRENT workspace
    /// and calls ``mobileChatRecordMatchesAgent(record:)``
    /// directly.
    private func mobileChatBindingIsCurrentAgent(_ record: AgentChatSessionRecord) -> Bool {
        guard let workspaceID = record.workspaceID,
              let surfaceID = record.surfaceID,
              let resolved = mobileResolveWorkspaceAndSurface(
                  params: ["workspace_id": workspaceID, "surface_id": surfaceID],
                  requireTerminal: true
              ),
              let surfaceId = resolved.surfaceId,
              resolved.workspace.controlSocketTerminalTarget(for: surfaceId) != nil else {
            return false
        }
        return mobileChatRecordMatchesAgent(record: record)
    }

    /// Agent-match core: whether the record's bound surface (already resolved to
    /// a live terminal by the caller) still hosts the agent.
    ///
    /// Deterministic per the agent-session spec (principle 2): the surface
    /// binding is authoritative — NEVER the terminal title or screen-scraped
    /// agent detection, which can both hide a correctly-bound live session (a
    /// renamed title or a scrolled-off banner) and mis-attribute. The reliable
    /// signal is process liveness: when cmux knows the agent pid, a live pid
    /// means the agent is still here and a dead pid means it is gone (the
    /// process-exit watcher ends it). When the pid is unknown — a session
    /// re-bound on resume from cmux's own authority, whose pid is not backfilled
    /// until the agent's own hooks arrive (e.g. an `sr codex resume` that
    /// bypasses the hook-injecting shim) — trust the durable surface binding
    /// rather than inventing a negative that would wrongly hide a live session.
    private func mobileChatRecordMatchesAgent(record: AgentChatSessionRecord) -> Bool {
        guard let pid = record.pid else { return true }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private func mobileChatTerminalTarget(sessionID: String) async -> ControlTerminalSocketTarget? {
        guard let terminalParams = await mobileChatTerminalParams(sessionID: sessionID),
              let resolved = mobileResolveWorkspaceAndSurface(params: terminalParams, requireTerminal: true),
              let surfaceId = resolved.surfaceId else {
            #if DEBUG
            cmuxDebugLog("mobile.chat terminal unresolved session=\(sessionID.prefix(8))")
            #endif
            return nil
        }
        return resolved.workspace.controlSocketTerminalTarget(for: surfaceId)
    }

}
