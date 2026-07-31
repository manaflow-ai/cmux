import Foundation

extension TerminalController {
    /// Delivers one mobile-composer block through the compound prompt
    /// primitive, or stages it without submitting when `submit_key=none`.
    func v2MobileTerminalPaste(params: [String: Any]) -> V2CallResult {
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
            let result = terminalPanel.sendPromptSubmissionResult(
                text,
                submitKey: submitKeyName,
                agentInputScope: agentInputScope,
                // This request is the human-owned mobile composer itself. The
                // automation-only rejection policy must not wedge it behind
                // stale physical-terminal ownership.
                rejectIfHumanComposerBusy: false,
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
            guard terminalPanel.sendText(text) else {
                return .err(
                    code: "surface_unavailable",
                    message: Self.terminalSurfaceUnavailableMessage,
                    data: ["surface_id": surfaceID.uuidString]
                )
            }
            terminalPanel.surface.recordHumanPromptInput(.unknown)
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
            "surface_id": terminalPanel.id.uuidString,
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
