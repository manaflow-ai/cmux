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
        case "mobile.chat.history":
            return await v2MobileChatHistory(params: params)
        case "mobile.chat.send":
            return v2MobileChatSend(params: params)
        case "mobile.chat.interrupt":
            return v2MobileChatInterrupt(params: params)
        case "mobile.chat.answer":
            return v2MobileChatAnswer(params: params)
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
    func v2MobileChatSessions(params: [String: Any]) -> V2CallResult {
        let workspaceID = v2String(params, "workspace_id")
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        // Register coding agents cmux detects by terminal title but that never
        // ran a hook (e.g. launched through a shell wrapper that bypasses
        // cmux's hook injection), so they get a chat session and toggle like
        // hook-registered agents.
        if let workspaceID {
            adoptDetectedAgentSessions(workspaceID: workspaceID)
        }
        let descriptors = service.sessionRecords(workspaceID: workspaceID)
            .filter { mobileChatBindingIsCurrentAgent($0) }
            .map(\.descriptor)
        let encoded = descriptors.compactMap { service.wirePayload($0) }
        return .ok(["sessions": encoded])
    }

    /// Scans a workspace's terminals for a running coding agent that has no
    /// chat session yet (title- or launch-metadata-detected, no hook) and
    /// adopts it. Adoption is a no-op once the surface has a session, so this
    /// only touches the filesystem the first time an agent is seen. Called
    /// both on a mobile session-list request and live from the terminal
    /// title-change observer, so the toggle appears the moment an agent
    /// launches, not only when the workspace is next opened.
    func adoptDetectedAgentSessions(workspaceID: String) {
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: ["workspace_id": workspaceID],
            requireTerminal: false
        ) else { return }
        adoptDetectedAgentSessions(workspace: resolved.workspace)
    }

    /// Surface-scoped title-change adoption path. Unlike the workspace-list
    /// sweep, this handles live terminal title churn and must avoid rescanning
    /// every terminal in the workspace.
    @discardableResult
    func adoptDetectedAgentSession(titleChange: GhosttyTitleChange) -> Bool {
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: [
                "workspace_id": titleChange.tabId.uuidString,
                "surface_id": titleChange.surfaceId.uuidString,
            ],
            requireTerminal: false
        ),
            let surfaceId = resolved.surfaceId,
            let panel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return false
        }
        return adoptDetectedAgentSession(
            workspace: resolved.workspace,
            panel: panel,
            title: titleChange.title
        )
    }

    /// Workspace-typed core of ``adoptDetectedAgentSessions(workspaceID:)``,
    /// for callers that already hold the `Workspace` (the workspace-list RPC
    /// enumerates every workspace and adopts inline, so the toggle is known
    /// before the user enters the workspace — no per-open resolution and no
    /// pop-in). Each `adoptDetectedClaudeSession` short-circuits in memory
    /// once the surface has a session, so a repeat scan of an already-adopted
    /// workspace touches no filesystem.
    func adoptDetectedAgentSessions(workspace: Workspace) {
        for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
            let title = workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle
            adoptDetectedAgentSession(workspace: workspace, panel: panel, title: title)
        }
    }

    @discardableResult
    private func adoptDetectedAgentSession(
        workspace: Workspace,
        panel: TerminalPanel,
        title: String
    ) -> Bool {
        guard let service = agentChatTranscriptService else { return false }
        let context = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        let normalizedTitle = title.lowercased()
        // Claude is the case the wrapper-launched workflow hits; detect by
        // launch metadata (hook PID key / initial command) or the live
        // terminal title claude sets ("✳ Claude Code", then "✳ <ai-title>").
        let isClaude = TextBoxAgentDetection.isClaudeCode(context: context)
            || normalizedTitle.contains("claude")
            || title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("✳")
        guard isClaude else { return false }
        let cwd = workspace.panelDirectories[panel.id]
            ?? (panel.directory.isEmpty ? nil : panel.directory)
            ?? (workspace.currentDirectory.isEmpty ? nil : workspace.currentDirectory)
        guard let cwd, !cwd.isEmpty else { return false }
        return service.adoptDetectedClaudeSession(
            workspaceID: workspace.id.uuidString,
            surfaceID: panel.id.uuidString,
            workingDirectory: cwd,
            titleHint: title
        )
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
            let refreshed = service.refreshSessionBindings(sessionID: sessionID)
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
                defaultValue: "This conversation's transcript isn't readable on the Mac yet. Send the agent a prompt from its terminal, then retry."
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
    func v2MobileChatSend(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let text = v2RawString(params, "text") ?? ""
        let attachments = params["attachments"] as? [[String: Any]] ?? []
        guard !text.isEmpty || !attachments.isEmpty else {
            return .err(code: "invalid_params", message: "Nothing to send", data: nil)
        }
        guard let terminalParams = mobileChatTerminalParams(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        guard let terminalPanel = mobileChatTerminalPanel(sessionID: sessionID) else {
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
    func v2MobileChatInterrupt(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let hard = (params["hard"] as? Bool) ?? false
        guard let terminalPanel = mobileChatTerminalPanel(sessionID: sessionID) else {
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
    func v2MobileChatAnswer(params: [String: Any]) -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id"),
              let optionIndex = v2Int(params, "option_index"), optionIndex >= 0, optionIndex < 9 else {
            return .err(code: "invalid_params", message: "Missing session_id or option_index", data: nil)
        }
        guard let terminalPanel = mobileChatTerminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.chatTerminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let digit = String(optionIndex + 1)
        let sendResult = terminalPanel.surface.sendInputResult(digit)
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
    private func mobileChatTerminalParams(sessionID: String) -> [String: Any]? {
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
        if let refreshed = service.refreshSessionBindings(sessionID: sessionID),
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
    private func mobileChatBindingIsCurrentAgent(_ record: AgentChatSessionRecord) -> Bool {
        guard let workspaceID = record.workspaceID,
              let surfaceID = record.surfaceID,
              let resolved = mobileResolveWorkspaceAndSurface(
                  params: ["workspace_id": workspaceID, "surface_id": surfaceID],
                  requireTerminal: true
              ),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return false
        }
        let title = resolved.workspace.panelTitle(panelId: terminalPanel.id) ?? terminalPanel.displayTitle
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let context = WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
        switch record.agentKind {
        case .claude:
            return TextBoxAgentDetection.isClaudeCode(context: context)
                || normalizedTitle.contains("claude")
                || title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("✳")
        case .codex:
            return TextBoxAgentDetection.codex.matches(context: context)
                || normalizedTitle.contains("codex")
        case .other(let source):
            return !source.isEmpty && (
                context.localizedCaseInsensitiveContains(source)
                    || normalizedTitle.contains(source.lowercased())
            )
        }
    }

    private func mobileChatTerminalPanel(sessionID: String) -> TerminalPanel? {
        guard let terminalParams = mobileChatTerminalParams(sessionID: sessionID),
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
