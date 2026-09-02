import CmuxTerminalCore
import Foundation

extension TerminalController {
    /// Maps a compound mobile prompt failure to the public mobile RPC error.
    /// Accepted outcomes stay `nil` so callers can preserve their success
    /// payload while waiting for a deferred delivery receipt.
    static func mobilePromptSubmissionFailure(
        _ result: PromptSubmissionSendResult,
        surfaceID: String,
        submitKey: String? = nil
    ) -> V2CallResult? {
        switch result {
        case .sent, .queued:
            return nil
        case .composerBusy:
            return .err(
                code: "rejected_composer_busy",
                message: Self.agentPromptComposerBusyMessage,
                data: [
                    "surface_id": surfaceID,
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
                    "surface_id": surfaceID,
                    "retryable": true,
                    "retry_after": "agent_terminal_ready",
                ]
            )
        case .unknownKey:
            return .err(
                code: "invalid_params",
                message: "Unsupported submit_key",
                data: submitKey.map {
                    ["submit_key": $0] as [String: Any]
                }
            )
        case .inputQueueFull:
            return .err(
                code: "input_queue_full",
                message: Self.terminalInputQueueFullMessage,
                data: ["surface_id": surfaceID]
            )
        case .surfaceUnavailable:
            return .err(
                code: "surface_unavailable",
                message: Self.terminalSurfaceUnavailableMessage,
                data: ["surface_id": surfaceID]
            )
        case .processExited:
            return .err(
                code: "process_exited",
                message: Self.terminalProcessExitedMessage,
                data: ["surface_id": surfaceID]
            )
        }
    }

    /// Delivers one mobile-composer block through the compound prompt
    /// primitive, or stages it without submitting when `submit_key=none`.
    func v2MobileTerminalPaste(
        params: [String: Any],
        rejectIfHumanComposerBusy: Bool = false,
        recordHumanPromptInput: Bool = true,
        deliveryReceipt: PromptSubmissionDeliveryReceipt? = nil
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
                context: agentContext,
                agentInputScope: agentInputScope
            )
        }
        _ = applyMobileViewportReport(
            params: params,
            terminalPanel: terminalPanel
        )

        var submitted = false
        var queued = false
        if let submitKeyName {
            // Exact mobile-chat automation is guarded by the same authoritative
            // agent scope as workspace.agent_submit. A transient identity gap
            // fails closed before any compatibility reset can be queued for a
            // different process.
            let rejectTrackedHumanComposer = rejectIfHumanComposerBusy
            // Keep the legacy composer reset inside the same indivisible
            // transaction whenever this exact mobile-chat path is guarded.
            // Tracked input is rejected before these keys are admitted; the
            // reset therefore covers only composer text that the ledger cannot
            // authoritatively observe (including restored TUI state).
            let preparationKeys =
                rejectIfHumanComposerBusy
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
                    ),
                recordHumanPromptInput: recordHumanPromptInput,
                deliveryReceipt: deliveryReceipt
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
            default:
                return Self.mobilePromptSubmissionFailure(
                    result,
                    surfaceID: surfaceID.uuidString,
                    submitKey: submitKeyName
                ) ?? .err(
                    code: "internal_error",
                    message: "Prompt delivery failed",
                    data: nil
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
