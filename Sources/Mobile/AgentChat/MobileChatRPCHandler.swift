import CMUXAgentLaunch
import CmuxAgentChat
import CmuxTerminal
import Foundation

/// Owns the `mobile.chat.*` RPC dispatch: the Mac side of the iOS agent chat
/// surface.
///
/// Session/transcript state lives in ``AgentChatTranscriptService``; the
/// send/interrupt/answer paths reuse the existing mobile terminal injection
/// machinery (through ``MobileChatRPCHost``) so chat input behaves exactly like
/// composer input. This type replaces the former `TerminalController+MobileChat`
/// extension: the same logic, relocated off the data-plane god object into a
/// constructor-injected owner that reaches the terminal data plane only through
/// the ``MobileChatRPCHost`` seam.
@MainActor
final class MobileChatRPCHandler {
    private let host: any MobileChatRPCHost

    /// - Parameter host: the terminal data-plane seam the chat handlers drive
    ///   (transcript service, workspace/surface resolution, terminal paste, and
    ///   the v2 param/error vocabulary).
    init(host: any MobileChatRPCHost) {
        self.host = host
    }

    /// Actionable error for a chat session whose terminal binding cannot be
    /// resolved even after a hook-store refresh. Surfaces verbatim in the iOS
    /// chat error banner, so it is localized.
    static var terminalBindingErrorMessage: String {
        String(
            localized: "mobile.chat.error.terminalMoved",
            defaultValue: "The agent's terminal moved. Open it once on your Mac (or send the agent any prompt there), then retry."
        )
    }

    /// Error shown when the Mac-side chat service is not wired into this
    /// process. Surfaces in mobile RPC error banners and debug responses.
    static var serviceUnavailableErrorMessage: String {
        String(
            localized: "mobile.chat.error.serviceUnavailable",
            defaultValue: "Agent chat transcript service is not configured"
        )
    }

    /// Routes one `mobile.chat.*` method to its handler (single dispatch case
    /// in `mobileHostHandleRPC` keeps the god-file growth flat).
    func dispatch(method: String, params: [String: Any]) async -> TerminalController.V2CallResult {
        switch method {
        case "mobile.chat.sessions":
            return sessions(params: params)
        case "mobile.chat.history":
            return await history(params: params)
        case "mobile.chat.send":
            return send(params: params)
        case "mobile.chat.interrupt":
            return interrupt(params: params)
        case "mobile.chat.answer":
            return answer(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }

    /// `chat.sessions.dump` (local debug socket, main-actor lane): the full
    /// chat-session registry state, for diagnosing inconsistent phone-side
    /// states.
    func sessionsDump() -> TerminalController.V2CallResult {
        guard let service = host.mobileChatTranscriptService else {
            return .err(code: "unavailable", message: Self.serviceUnavailableErrorMessage, data: nil)
        }
        return .ok(["sessions": service.debugSessionDump()])
    }

    /// `mobile.chat.sessions`: list chat-capable coding-agent sessions,
    /// optionally scoped to one workspace.
    func sessions(params: [String: Any]) -> TerminalController.V2CallResult {
        let workspaceID = host.mobileChatStringParam(params, "workspace_id")
        guard let service = host.mobileChatTranscriptService else {
            return .err(code: "unavailable", message: Self.serviceUnavailableErrorMessage, data: nil)
        }
        // Register coding agents cmux detects by terminal title but that never
        // ran a hook (e.g. launched through a shell wrapper that bypasses
        // cmux's hook injection), so they get a chat session and toggle like
        // hook-registered agents.
        if let workspaceID {
            adoptDetectedAgentSessions(workspaceID: workspaceID)
        }
        let descriptors = service.sessionRecords(workspaceID: workspaceID)
            .filter { bindingIsCurrentAgent($0) }
            .map(\.descriptor)
        let encoded = descriptors.compactMap { service.wirePayload($0) }
        return .ok(["sessions": encoded])
    }

    /// Scans a workspace's terminals for a running coding agent that has no
    /// chat session yet (title- or launch-metadata-detected, no hook) and
    /// adopts it. Adoption is a no-op once the surface has a session, so this
    /// only touches the filesystem the first time an agent is seen. Called both
    /// on a mobile session-list request and live from the terminal
    /// title-change observer, so the toggle appears the moment an agent
    /// launches, not only when the workspace is next opened.
    func adoptDetectedAgentSessions(workspaceID: String) {
        guard let resolved = host.mobileChatResolveWorkspaceAndSurface(
            params: ["workspace_id": workspaceID],
            requireTerminal: false
        ) else { return }
        adoptDetectedAgentSessions(workspace: resolved.workspace)
    }

    /// Workspace-typed core of ``adoptDetectedAgentSessions(workspaceID:)``, for
    /// callers that already hold the `Workspace` (the workspace-list RPC
    /// enumerates every workspace and adopts inline, so the toggle is known
    /// before the user enters the workspace — no per-open resolution and no
    /// pop-in). Each `adoptDetectedClaudeSession` short-circuits in memory once
    /// the surface has a session, so a repeat scan of an already-adopted
    /// workspace touches no filesystem.
    func adoptDetectedAgentSessions(workspace: Workspace) {
        let workspaceID = workspace.id.uuidString
        guard let service = host.mobileChatTranscriptService else { return }
        for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
            let context = workspace.terminalAgentContext(panel: panel)
            let title = workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle
            let normalizedTitle = title.lowercased()
            // Claude is the case the wrapper-launched workflow hits; detect by
            // launch metadata (hook PID key / initial command) or the live
            // terminal title claude sets ("✳ Claude Code", then "✳ <ai-title>").
            let isClaude = TextBoxAgentDetection.isClaudeCode(context: context)
                || normalizedTitle.contains("claude")
                || title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("✳")
            guard isClaude else { continue }
            let cwd = workspace.panelDirectories[panel.id]
                ?? (panel.directory.isEmpty ? nil : panel.directory)
                ?? (workspace.currentDirectory.isEmpty ? nil : workspace.currentDirectory)
            guard let cwd, !cwd.isEmpty else { continue }
            service.adoptDetectedClaudeSession(
                workspaceID: workspaceID,
                surfaceID: panel.id.uuidString,
                workingDirectory: cwd,
                titleHint: title
            )
        }
    }

    /// `mobile.chat.history`: one transcript page for a session.
    func history(params: [String: Any]) async -> TerminalController.V2CallResult {
        guard let sessionID = host.mobileChatRawStringParam(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let limit = min(max(host.mobileChatIntParam(params, "limit") ?? 100, 1), 200)
        let beforeSeq = host.mobileChatIntParam(params, "before_seq")
        guard let service = host.mobileChatTranscriptService else {
            return .err(code: "unavailable", message: Self.serviceUnavailableErrorMessage, data: nil)
        }
        var page = await service.history(sessionID: sessionID, beforeSeq: beforeSeq, limit: limit)
        if page == nil, let staleRecord = service.sessionRecord(sessionID: sessionID) {
            // The record exists but its transcript didn't resolve — the
            // recorded path can be stale the same way terminal bindings are.
            // Re-adopt from the hook store and retry once, but only when the
            // refresh actually changed the resolution inputs (a pointless retry
            // re-runs the codex directory walk).
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

    /// `mobile.chat.send`: deliver attachments then inject the prompt into the
    /// session's terminal (bracketed paste + submit key).
    func send(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let sessionID = host.mobileChatRawStringParam(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let text = host.mobileChatRawStringParam(params, "text") ?? ""
        let attachments = params["attachments"] as? [[String: Any]] ?? []
        guard !text.isEmpty || !attachments.isEmpty else {
            return .err(code: "invalid_params", message: "Nothing to send", data: nil)
        }
        guard let terminalParams = terminalParams(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.terminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        guard let terminalPanel = terminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.terminalBindingErrorMessage, data: [
                "session_id": sessionID
            ])
        }
        let clearResult = clearPrompt(terminalPanel)
        guard clearResult.accepted else {
            return inputError(clearResult)
        }
        for (index, attachment) in attachments.enumerated() {
            guard let base64 = attachment["data_b64"] as? String else {
                return .err(code: "invalid_params", message: "Attachment missing data_b64", data: nil)
            }
            var imageParams = terminalParams
            imageParams["image_base64"] = base64
            imageParams["image_format"] = (attachment["format"] as? String) ?? "png"
            let result = host.mobileChatPasteImage(params: imageParams)
            if case .err = result {
                return result
            }
            // Separate each pasted path from the next path or the prompt (the
            // local Mac paste joins with spaces too) so the agent detects the
            // paths and the echo is "<path> <path> <text>" — the shape the
            // client's pending-row reconcile matches. A dropped separator
            // corrupts that shape; surface it.
            let needsSeparator = index < attachments.count - 1 || !text.isEmpty
            if needsSeparator {
                let separatorResult = terminalPanel.surface.sendInputResult(" ")
                switch separatorResult {
                case .sent, .queued:
                    break
                case .inputQueueFull:
                    return .err(code: "input_queue_full", message: host.mobileChatInputQueueFullMessage, data: nil)
                case .surfaceUnavailable:
                    return .err(code: "surface_unavailable", message: host.mobileChatSurfaceUnavailableMessage, data: nil)
                case .processExited:
                    return .err(code: "process_exited", message: host.mobileChatProcessExitedMessage, data: nil)
                }
            }
        }
        guard !text.isEmpty else {
            // Attachment-only send: the image path is sitting pasted at the
            // agent's prompt; submit it so the send actually reaches the agent
            // instead of idling in the line editor.
            let keyResult = terminalPanel.sendNamedKeyResult("return")
            return .ok(["submitted": keyResult.accepted])
        }
        var pasteParams = terminalParams
        pasteParams["text"] = text
        return host.mobileChatPasteText(params: pasteParams)
    }

    /// Clears any stale text already sitting in the agent's terminal prompt
    /// before the mobile chat prompt is pasted and submitted.
    private func clearPrompt(_ terminalPanel: TerminalPanel) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }

    /// `mobile.chat.interrupt`: polite (Esc) or hard (ctrl-C) interrupt of the
    /// session's agent.
    func interrupt(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let sessionID = host.mobileChatRawStringParam(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let hard = (params["hard"] as? Bool) ?? false
        guard let terminalPanel = terminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.terminalBindingErrorMessage, data: [
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
    func answer(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let sessionID = host.mobileChatRawStringParam(params, "session_id"),
              let optionIndex = host.mobileChatIntParam(params, "option_index"), optionIndex >= 0, optionIndex < 9 else {
            return .err(code: "invalid_params", message: "Missing session_id or option_index", data: nil)
        }
        guard let terminalPanel = terminalPanel(sessionID: sessionID) else {
            return .err(code: "not_found", message: Self.terminalBindingErrorMessage, data: [
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
    /// The session is bound to a specific terminal (its surface id). Surface ids
    /// are stable across relaunch/restore now, so the recorded surface keeps
    /// resolving; a still-stale binding is re-adopted once from the hook store
    /// (every hook event rewrites it with the current panel) and retried. If it
    /// still doesn't resolve we fail with an actionable error rather than
    /// redirect the prompt to some other terminal.
    private func terminalParams(sessionID: String) -> [String: Any]? {
        guard let service = host.mobileChatTranscriptService else { return nil }
        guard let record = service.sessionRecord(sessionID: sessionID),
              let workspaceID = record.workspaceID else {
            return nil
        }
        if let surfaceID = record.surfaceID,
           bindingResolves(workspaceID: workspaceID, surfaceID: surfaceID),
           bindingIsCurrentAgent(record) {
            return ["workspace_id": workspaceID, "surface_id": surfaceID]
        }
        #if DEBUG
        cmuxDebugLog("mobile.chat binding stale session=\(sessionID.prefix(8)) surface=\(record.surfaceID?.prefix(8) ?? "nil"); refreshing from hook store")
        #endif
        if let refreshed = service.refreshSessionBindings(sessionID: sessionID),
           let surfaceID = refreshed.surfaceID,
           bindingResolves(workspaceID: workspaceID, surfaceID: surfaceID),
           bindingIsCurrentAgent(refreshed) {
            return ["workspace_id": workspaceID, "surface_id": surfaceID]
        }
        #if DEBUG
        cmuxDebugLog("mobile.chat binding unresolved session=\(sessionID.prefix(8))")
        #endif
        return nil
    }

    /// Whether a workspace/surface pair resolves to a live terminal panel.
    private func bindingResolves(workspaceID: String, surfaceID: String) -> Bool {
        let params: [String: Any] = ["workspace_id": workspaceID, "surface_id": surfaceID]
        guard let resolved = host.mobileChatResolveWorkspaceAndSurface(params: params, requireTerminal: true),
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
    private func bindingIsCurrentAgent(_ record: AgentChatSessionRecord) -> Bool {
        guard let workspaceID = record.workspaceID,
              let surfaceID = record.surfaceID,
              let resolved = host.mobileChatResolveWorkspaceAndSurface(
                  params: ["workspace_id": workspaceID, "surface_id": surfaceID],
                  requireTerminal: true
              ),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return false
        }
        let title = resolved.workspace.panelTitle(panelId: terminalPanel.id) ?? terminalPanel.displayTitle
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let context = resolved.workspace.terminalAgentContext(panel: terminalPanel)
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

    private func terminalPanel(sessionID: String) -> TerminalPanel? {
        guard let terminalParams = terminalParams(sessionID: sessionID),
              let resolved = host.mobileChatResolveWorkspaceAndSurface(params: terminalParams, requireTerminal: true),
              let surfaceId = resolved.surfaceId else {
            #if DEBUG
            cmuxDebugLog("mobile.chat terminal unresolved session=\(sessionID.prefix(8))")
            #endif
            return nil
        }
        return resolved.workspace.terminalPanel(for: surfaceId)
    }

    private func inputError(_ keyResult: TerminalSurface.NamedKeySendResult) -> TerminalController.V2CallResult {
        switch keyResult {
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: host.mobileChatInputQueueFullMessage, data: nil)
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: host.mobileChatSurfaceUnavailableMessage, data: nil)
        case .processExited:
            return .err(code: "process_exited", message: host.mobileChatProcessExitedMessage, data: nil)
        case .unknownKey:
            return .err(code: "surface_unavailable", message: host.mobileChatSurfaceUnavailableMessage, data: nil)
        case .sent, .queued:
            return .ok(["accepted": true])
        }
    }
}
