import CmuxAgentChat
import Foundation

/// `mobile.chat.*` RPC handlers: the Mac side of the iOS agent chat
/// surface. Session/transcript state lives in
/// ``AgentChatTranscriptService``; the send/interrupt/answer paths reuse
/// the existing mobile terminal injection machinery so chat input behaves
/// exactly like composer input.
extension TerminalController {
    /// Actionable error for a chat session whose terminal binding cannot
    /// be resolved even after a hook-store refresh.
    static let chatTerminalBindingErrorMessage =
        "The agent's terminal moved. Open it once on your Mac (or send the agent any prompt there), then retry."

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
        .ok(["sessions": AgentChatTranscriptService.shared.debugSessionDump()])
    }

    /// `mobile.chat.sessions`: list chat-capable sessions, optionally
    /// scoped to one workspace. Merges agent (hook) sessions with EVERY open
    /// terminal surface so a plain terminal tab is chat-capable too (the
    /// phone's per-tab toggle shows iff its surface appears here). A surface
    /// already represented by an agent session is not listed twice.
    func v2MobileChatSessions(params: [String: Any]) -> V2CallResult {
        let workspaceID = v2String(params, "workspace_id")
        let service = AgentChatTranscriptService.shared
        let agentDescriptors = service.sessionDescriptors(workspaceID: workspaceID)
        let agentSurfaceIDs = Set(agentDescriptors.compactMap { $0.terminalID })
        let terminalDescriptors = terminalChatDescriptors(workspaceID: workspaceID)
            .filter { descriptor in
                guard let surfaceID = descriptor.terminalID else { return true }
                return !agentSurfaceIDs.contains(surfaceID)
            }
        let encoded = (agentDescriptors + terminalDescriptors).compactMap { service.wirePayload($0) }
        return .ok(["sessions": encoded])
    }

    /// `mobile.chat.history`: one transcript page for a session.
    func v2MobileChatHistory(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let limit = min(max(v2Int(params, "limit") ?? 100, 1), 200)
        let beforeSeq = v2Int(params, "before_seq")
        let service = AgentChatTranscriptService.shared
        // A terminal session's id is its surface UUID (unambiguous: agent
        // session ids are hook session_ids). Serve its command-block log from
        // the byte tee before the agent path.
        if let terminalPage = terminalChatHistoryPage(sessionID: sessionID) {
            guard let payload = service.wirePayload(terminalPage) else {
                return .err(code: "internal_error", message: "History encoding failed", data: nil)
            }
            return .ok(payload)
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
            let refreshed = AgentChatTranscriptService.shared.refreshSessionBindings(sessionID: sessionID)
            if refreshed?.transcriptPath != staleRecord.transcriptPath
                || refreshed?.workingDirectory != staleRecord.workingDirectory {
                page = await service.history(sessionID: sessionID, beforeSeq: beforeSeq, limit: limit)
            }
        }
        guard let page else {
            #if DEBUG
            cmuxDebugLog("mobile.chat.history not_found session=\(sessionID.prefix(8))")
            #endif
            return .err(code: "not_found", message: "This conversation's transcript isn't readable on the Mac yet. Send the agent a prompt from its terminal, then retry.", data: [
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
            if needsSeparator, let terminalPanel = mobileChatTerminalPanel(sessionID: sessionID) {
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
            guard let terminalPanel = mobileChatTerminalPanel(sessionID: sessionID) else {
                return .ok(["submitted": false])
            }
            let keyResult = terminalPanel.sendNamedKeyResult("return")
            return .ok(["submitted": keyResult.accepted])
        }
        var pasteParams = terminalParams
        pasteParams["text"] = text
        return v2MobileTerminalPaste(params: pasteParams)
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
            return .err(code: "surface_unavailable", message: "Interrupt key was not accepted", data: nil)
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
            return .err(code: "surface_unavailable", message: "Answer key was not accepted", data: nil)
        }
    }

    /// Workspace/surface params for a chat session's bound terminal, in the
    /// shape the existing mobile terminal handlers expect.
    private func mobileChatTerminalParams(sessionID: String) -> [String: Any]? {
        guard let record = mobileChatResolvableRecord(sessionID: sessionID),
              let workspaceID = record.workspaceID,
              let surfaceID = record.surfaceID else {
            return nil
        }
        return ["workspace_id": workspaceID, "surface_id": surfaceID]
    }

    /// The session record, with its terminal binding verified against live
    /// panels. A stale binding (panel UUIDs regenerate across app
    /// relaunches) is refreshed once from the hook store, which every hook
    /// event rewrites with the current panel.
    private func mobileChatResolvableRecord(sessionID: String) -> AgentChatSessionRecord? {
        let service = AgentChatTranscriptService.shared
        guard var record = service.sessionRecord(sessionID: sessionID) else { return nil }
        if !mobileChatBindingResolves(record) {
            #if DEBUG
            cmuxDebugLog("mobile.chat binding stale session=\(sessionID.prefix(8)) surface=\(record.surfaceID?.prefix(8) ?? "nil"); refreshing from hook store")
            #endif
            record = service.refreshSessionBindings(sessionID: sessionID) ?? record
            guard mobileChatBindingResolves(record) else {
                // Still dead after the refresh (no hook has run since the
                // panel changed): fail with the actionable binding error
                // rather than letting the paste path report a generic
                // surface-not-found.
                #if DEBUG
                cmuxDebugLog("mobile.chat binding unresolved after refresh session=\(sessionID.prefix(8))")
                #endif
                return nil
            }
        }
        return record
    }

    private func mobileChatBindingResolves(_ record: AgentChatSessionRecord) -> Bool {
        guard let workspaceID = record.workspaceID, let surfaceID = record.surfaceID else { return false }
        let params: [String: Any] = ["workspace_id": workspaceID, "surface_id": surfaceID]
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              resolved.workspace.terminalPanel(for: surfaceId) != nil else {
            return false
        }
        return true
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
}

// MARK: - Terminal sessions as chat (Slice D)

extension TerminalController {
    /// Every open terminal surface, across all main windows, as a
    /// chat-capable descriptor (`kind: .terminal`). The session id is the
    /// surface UUID. The title is a placeholder — the phone overrides the
    /// header with the workspace + tab name — so any open terminal tab gets
    /// the chat toggle, not just hook-registered agent sessions.
    func terminalChatDescriptors(workspaceID: String?) -> [ChatSessionDescriptor] {
        guard let app = AppDelegate.shared else { return [] }
        var descriptors: [ChatSessionDescriptor] = []
        var seenWorkspaces: Set<UUID> = []
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in tabManager.tabs where seenWorkspaces.insert(workspace.id).inserted {
                if let workspaceID, workspace.id.uuidString != workspaceID { continue }
                for panel in workspace.panels.values {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let surfaceID = terminal.id.uuidString
                    descriptors.append(
                        ChatSessionDescriptor(
                            id: surfaceID,
                            agentKind: .other("terminal"),
                            kind: .terminal,
                            title: terminal.displayTitle,
                            workspaceID: workspace.id.uuidString,
                            terminalID: surfaceID,
                            state: .idle
                        )
                    )
                }
            }
        }
        return descriptors
    }

    /// The command-block log for a terminal surface, parsed on demand from
    /// the byte tee's replay ring. Returns `nil` when `sessionID` is not a
    /// known terminal surface, so the agent history path runs instead.
    func terminalChatHistoryPage(sessionID: String) -> ChatHistoryPage? {
        guard let surfaceID = UUID(uuidString: sessionID),
              isKnownTerminalSurface(surfaceID) else { return nil }
        var blocks: [TerminalCommandBlock] = []
        if let replay = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceID),
           !replay.data.isEmpty {
            let parser = OSC133CommandParser()
            parser.consume(String(decoding: replay.data, as: UTF8.self))
            blocks = parser.blocks
        }
        return ChatHistoryPage(messages: [], hasMore: false, terminalBlocks: blocks)
    }

    private func isKnownTerminalSurface(_ surfaceID: UUID) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in tabManager.tabs where workspace.terminalPanel(for: surfaceID) != nil {
                return true
            }
        }
        return false
    }
}
