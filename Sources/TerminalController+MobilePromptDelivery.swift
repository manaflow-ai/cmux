import Foundation

extension TerminalController {
    /// Delivers one mobile-composer block through the compound prompt
    /// primitive, or stages it without submitting when `submit_key=none`.
    func v2MobileTerminalPaste(
        params: [String: Any],
        rejectIfHumanComposerBusy: Bool = false
    ) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "Missing text",
                data: nil
            )
        }

        let submitKeyRaw =
            (v2String(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(
                code: "invalid_params",
                message: "Unsupported submit_key",
                data: ["submit_key": submitKeyRaw]
            )
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: params,
            requireTerminal: true
        ),
              let surfaceID = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalInputTarget(
                  forPanelID: surfaceID
              )?.panel else {
            return .err(
                code: "not_found",
                message: "Terminal surface not found",
                data: nil
            )
        }

        let agentContext = WorkspaceContentView.terminalAgentContext(
            panel: terminalPanel,
            workspace: resolved.workspace
        )
        let agentInputScope = resolved.workspace.agentPromptInputScope(
            forPanelId: terminalPanel.id
        )
        if submitKeyWasReturnIntent {
            submitKeyName = TextBoxAgentDetection.composedPromptSubmitKey(
                containsNewline: text.contains("\n") || text.contains("\r"),
                context: agentContext
            )
        }
        _ = applyMobileViewportReport(
            params: params,
            terminalPanel: terminalPanel
        )

        var submitted = false
        var queued = false
        if let submitKeyName {
            // Mobile chat is an existing human-owned send surface. Preserve its
            // prior delivery behavior during a transient process-identity gap,
            // while still rejecting a tracked Mac-side draft whenever an
            // authoritative scope exists. workspace.agent_submit remains
            // strictly fail-closed when that scope is unavailable.
            let rejectTrackedHumanComposer =
                rejectIfHumanComposerBusy && agentInputScope != nil
            // The legacy pre-binding clear remains app-owned by traveling with
            // the paste and submit key in one indivisible transaction. Generic
            // named-key delivery would incorrectly claim human composer state.
            let preparationKeys =
                rejectIfHumanComposerBusy && agentInputScope == nil
                    ? ["ctrl+a", "ctrl+k", "ctrl+u"]
                    : []
            let result = terminalPanel.sendPromptSubmissionResult(
                text,
                submitKey: submitKeyName,
                preparationKeys: preparationKeys,
                agentInputScope: agentInputScope,
                // Low-level mobile.terminal.paste is the human-owned composer
                // itself. Exact-message callers such as mobile.chat.send
                // reject a tracked draft without making a transient tracking
                // gap a regression in the existing human-owned send flow.
                rejectIfHumanComposerBusy: rejectTrackedHumanComposer,
                hookRecordingSource:
                    TextBoxAgentDetection.supportsActiveAgentPrefixes(
                        context: agentContext
                    )
                        ? "workspace.prompt_submit"
                        : nil,
                hookConfirmsHumanInput:
                    TextBoxAgentDetection.supportsActiveAgentPrefixes(
                        context: agentContext
                    )
            )
            switch result {
            case .sent:
                submitted = true
                terminalPanel.surface.forceRefresh(
                    reason: "mobileHost.terminalPaste"
                )
            case .queued:
                submitted = true
                queued = true
            case .composerBusy:
                return .err(
                    code: "rejected_composer_busy",
                    message: Self.agentPromptComposerBusyMessage,
                    data: [
                        "surface_id": surfaceID.uuidString,
                        "retryable": true,
                        "retry_after":
                            "human_prompt_submit_or_agent_restart",
                    ]
                )
            case .agentScopeUnavailable:
                return .err(
                    code: "agent_scope_unavailable",
                    message: Self.agentPromptScopeUnavailableMessage,
                    data: [
                        "surface_id": surfaceID.uuidString,
                        "retryable": true,
                        "retry_after": "agent_terminal_ready",
                    ]
                )
            case .unknownKey:
                return .err(
                    code: "invalid_params",
                    message: "Unsupported submit_key",
                    data: ["submit_key": submitKeyName]
                )
            case .inputQueueFull:
                return .err(
                    code: "input_queue_full",
                    message: Self.terminalInputQueueFullMessage,
                    data: ["surface_id": surfaceID.uuidString]
                )
            case .surfaceUnavailable:
                return .err(
                    code: "surface_unavailable",
                    message: Self.terminalSurfaceUnavailableMessage,
                    data: ["surface_id": surfaceID.uuidString]
                )
            case .processExited:
                return .err(
                    code: "process_exited",
                    message: Self.terminalProcessExitedMessage,
                    data: ["surface_id": surfaceID.uuidString]
                )
            }
        } else {
            terminalPanel.surface.synchronizePromptInputAgentScope(
                agentInputScope
            )
            guard terminalPanel.sendText(text) else {
                return .err(
                    code: "surface_unavailable",
                    message: Self.terminalSurfaceUnavailableMessage,
                    data: ["surface_id": surfaceID.uuidString]
                )
            }
            terminalPanel.surface.forceRefresh(
                reason: "mobileHost.terminalPaste"
            )
        }

        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceID.uuidString.prefix(8)) chars=\(text.count) submitted=\(submitted ? 1 : 0)"
        )
        #endif

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "submitted": submitted,
            "queued": queued,
        ]
        if let sequence = MobileTerminalByteTee.shared.currentSequence(
            surfaceID: surfaceID
        ) {
            payload["terminal_seq"] = sequence
        }
        return .ok(payload)
    }
}
