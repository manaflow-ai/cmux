import CmuxAgentChat
import CmuxTerminal
import Foundation

/// `mobile.chat.*` RPC handlers: the Mac side of the iOS agent chat
/// surface. Session/transcript state lives in
/// ``AgentChatTranscriptService``; the send/interrupt/answer paths reuse
/// the existing mobile terminal injection machinery so chat input behaves
/// exactly like composer input.
extension TerminalController {
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

    /// Routes one `mobile.chat.*` method to its handler (single dispatch
    /// case in `mobileHostHandleRPC` keeps the god-file growth flat).
    func v2MobileChatDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch method {
        case "mobile.chat.sessions":
            return v2MobileChatSessions(params: params)
        case "mobile.chat.session":
            return v2MobileChatSession(params: params)
        case "mobile.chat.history":
            return await v2MobileChatHistory(params: params)
        case "mobile.chat.send":
            return await v2MobileChatSend(params: params)
        case "mobile.chat.interrupt":
            return await v2MobileChatInterrupt(params: params)
        case "mobile.chat.answer":
            return await v2MobileChatAnswer(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
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
    func v2MobileChatSessions(params: [String: Any]) -> V2CallResult {
        let workspaceID = v2String(params, "workspace_id")
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        // Observe-floor detection: kick a throttled, off-main process-table scan
        // so a live codex/claude launched through any indirection (a subrouter, a
        // wrapper) that fired no hook is still discovered. Fire-and-forget: a new
        // detection creates a record that pushes itself to subscribers via
        // onRecordChanged, so it lands without blocking this list pull.
        Task { await service.observeAgentProcesses() }
        guard let workspaceID else {
            // No filter: return all current-agent sessions across workspaces,
            // resolving each via its stored binding as before.
            let descriptors = service.sessionRecords(workspaceID: nil)
                .filter { mobileChatBindingIsCurrentAgent($0) }
                .map(\.descriptor)
            let encoded = descriptors.compactMap { service.wirePayload($0) }
            return .ok(["sessions": encoded])
        }
        // Resolve W to its live Workspace once; build the set of its live
        // terminal surface ids once, then filter sessions against that set.
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: ["workspace_id": workspaceID],
            requireTerminal: false
        ) else {
            return .ok(["sessions": []])
        }
        let workspace = resolved.workspace
        var encoded: [[String: Any]] = []
        for record in service.sessionRecords(workspaceID: nil) {
            guard let surfaceID = record.surfaceID,
                  let surfaceUUID = UUID(uuidString: surfaceID),
                  workspace.terminalPanel(for: surfaceUUID) != nil else {
                continue
            }
            // A LIVE session must still be the current agent on the terminal, so
            // a reused/restored terminal never exposes a false live toggle. An
            // ENDED session is RETAINED whenever its surface is a live terminal
            // in W, regardless of what the terminal runs now: the GUI keeps a
            // finished conversation visible read-only (input bar disabled), so a
            // fresh pull must not drop it — dropping it is what made the toggle
            // go stale and vanish on tap after the agent exited.
            if record.state != .ended,
               !mobileChatRecordMatchesAgent(record: record) {
                continue
            }
            // Re-stamp stale-workspace records to W so the seed and live pushes
            // both scope to the current workspace, then encode the re-stamped
            // descriptor.
            if record.workspaceID != workspaceID {
                service.updateSessionWorkspace(sessionID: record.sessionID, workspaceID: workspaceID)
            }
            let descriptor = service.sessionRecord(sessionID: record.sessionID)?.descriptor ?? record.descriptor
            if let payload = service.wirePayload(descriptor) {
                encoded.append(payload)
            }
        }
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
        let text = v2RawString(params, "text") ?? ""
        let attachments = params["attachments"] as? [[String: Any]] ?? []
        guard !text.isEmpty || !attachments.isEmpty else {
            return .err(code: "invalid_params", message: "Nothing to send", data: nil)
        }
        guard let terminalParams = await mobileChatTerminalParams(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        guard let terminalPanel = await mobileChatTerminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let clearResult = mobileChatClearPrompt(terminalPanel)
        guard clearResult.accepted else {
            return mobileChatInputError(clearResult)
        }
        for (index, attachment) in attachments.enumerated() {
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
            // Separate each pasted path from the next path or the prompt
            // (the local Mac paste joins with spaces too) so the agent
            // detects the paths and the echo is "<path> <path> <text>" —
            // the shape the client's pending-row reconcile matches. A
            // dropped separator corrupts that shape; surface it.
            let needsSeparator = index < attachments.count - 1 || !text.isEmpty
            if needsSeparator {
                let separatorResult = terminalPanel.surface.sendInputResult(" ")
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
            let keyResult = terminalPanel.sendNamedKeyResult("return")
            return .ok(["submitted": keyResult.accepted])
        }
        var pasteParams = terminalParams
        pasteParams["text"] = text
        return v2MobileTerminalPaste(params: pasteParams)
    }

    /// Clears any stale text already sitting in the agent's terminal prompt
    /// before the mobile chat prompt is pasted and submitted.
    private func mobileChatClearPrompt(_ terminalPanel: TerminalPanel) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }

    /// `mobile.chat.interrupt`: polite (Esc) or hard (ctrl-C) interrupt of
    /// the session's agent.
    func v2MobileChatInterrupt(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let hard = (params["hard"] as? Bool) ?? false
        guard let terminalPanel = await mobileChatTerminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let keyResult = terminalPanel.sendNamedKeyResult(hard ? "ctrl+c" : "escape")
        guard keyResult.accepted else {
            return .err(code: "surface_unavailable", message: String(
                localized: "mobile.chat.error.interruptNotAccepted",
                defaultValue: "Interrupt key was not accepted"
            ), data: nil)
        }
        terminalPanel.surface.forceRefresh(reason: "mobileHost.chatInterrupt")
        return .ok(["interrupted": true, "hard": hard])
    }

    /// `mobile.chat.answer`: answer an in-terminal choice by display index
    /// (agent TUIs accept the option's number key).
    func v2MobileChatAnswer(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"),
              let optionIndex = v2Int(params, "option_index"), optionIndex >= 0, optionIndex < 9 else {
            return .err(code: "invalid_params", message: "Missing session_id or option_index", data: nil)
        }
        guard let terminalPanel = await mobileChatTerminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        // Claude's picker submits on the digit alone; Codex's `request_user_input`
        // picker highlights on the digit and needs Enter to submit ("enter to
        // submit answer"), so append a carriage return for codex.
        let digit = String(optionIndex + 1)
        let isCodex = agentChatTranscriptService?.sessionRecord(sessionID: sessionID)?.agentKind == .codex
        let answerKeys = isCodex ? "\(digit)\r" : digit
        let sendResult = terminalPanel.surface.sendInputResult(answerKeys)
        switch sendResult {
        case .sent, .queued:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.chatAnswer")
            return .ok(["answered": true, "option_index": optionIndex])
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            return .err(code: "surface_unavailable", message: String(
                localized: "mobile.chat.error.answerNotAccepted",
                defaultValue: "Answer key was not accepted"
            ), data: nil)
        }
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
              resolved.workspace.terminalPanel(for: surfaceId) != nil else {
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
    /// and calls ``mobileChatRecordMatchesAgent(record:workspace:terminalPanel:)``
    /// directly.
    private func mobileChatBindingIsCurrentAgent(_ record: AgentChatSessionRecord) -> Bool {
        guard let workspaceID = record.workspaceID,
              let surfaceID = record.surfaceID,
              let resolved = mobileResolveWorkspaceAndSurface(
                  params: ["workspace_id": workspaceID, "surface_id": surfaceID],
                  requireTerminal: true
              ),
              let surfaceId = resolved.surfaceId,
              resolved.workspace.terminalPanel(for: surfaceId) != nil else {
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

    private func mobileChatTerminalPanel(sessionID: String) async -> TerminalPanel? {
        guard let terminalParams = await mobileChatTerminalParams(sessionID: sessionID),
              let resolved = mobileResolveWorkspaceAndSurface(params: terminalParams, requireTerminal: true),
              let surfaceId = resolved.surfaceId else {
            #if DEBUG
            cmuxDebugLog("mobile.chat terminal unresolved session=\(sessionID.prefix(8))")
            #endif
            return nil
        }
        return resolved.workspace.terminalPanel(for: surfaceId)
    }

    private func mobileChatInputError(_ keyResult: TerminalSurface.NamedKeySendResult) -> V2CallResult {
        switch keyResult {
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: nil)
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: nil)
        case .unknownKey:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
        case .sent, .queued:
            return .ok(["accepted": true])
        }
    }
}
