import CmuxAgentChat
import Darwin
import Foundation

extension TerminalController {
    func sendDesignModePrompt(_ prompt: String, in workspace: Workspace) throws {
        guard let service = agentChatTranscriptService else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        let targets = service.sessionRecords(workspaceID: nil).compactMap { record -> (
            record: AgentChatSessionRecord,
            terminal: TerminalPanel
        )? in
            guard record.state != .ended,
                  let surfaceID = record.surfaceID,
                  service.registry.liveSession(surfaceID: surfaceID)?.sessionID == record.sessionID,
                  let surfaceUUID = UUID(uuidString: surfaceID),
                  let terminal = workspace.terminalPanel(for: surfaceUUID) else { return nil }
            return (record, terminal)
        }
        guard targets.count == 1, let target = targets.first else {
            throw targets.isEmpty
                ? BrowserDesignModeSendError.terminalUnavailable
                : BrowserDesignModeSendError.multipleAgentTerminals
        }
        guard target.record.state == .idle else {
            throw BrowserDesignModeSendError.agentBusy
        }
        let terminal = target.terminal
        if let pid = target.record.pid {
            guard let exactPID = pid_t(exactly: pid),
                  let liveTarget = AppDelegate.shared?.liveAgentDeliveryTarget(forAgentPID: exactPID),
                  liveTarget.workspaceId == workspace.id,
                  liveTarget.surfaceId == terminal.id else {
                throw BrowserDesignModeSendError.terminalUnavailable
            }
        }
        guard terminal.sessionTextBoxDraftSnapshot() == nil else {
            throw BrowserDesignModeSendError.agentComposerNotEmpty
        }
        guard clearAgentPrompt(terminal).accepted else {
            throw BrowserDesignModeSendError.promptClearUnavailable
        }
        guard terminal.sendText(prompt) else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        let submitKey = TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: prompt.contains("\n") || prompt.contains("\r"),
            agentKind: target.record.agentKind
        )
        guard terminal.sendNamedKeyResult(submitKey).accepted else {
            throw BrowserDesignModeSendError.submitUnavailable
        }
    }

    nonisolated func v2BrowserDesignMode(
        params: [String: Any],
        statusOnly: Bool
    ) -> V2CallResult {
        let mode = (v2String(params, "mode") ?? "toggle").lowercased()
        guard statusOnly || ["enable", "disable", "toggle"].contains(mode) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.designMode.rpcExpectedModes",
                    defaultValue: "mode must be one of: enable, disable, toggle"
                ),
                data: nil
            )
        }
        return v2BrowserWithPanelContext(
            params: params,
            allowSoleBrowserFallback: true
        ) { context in
            let panel = context.browserPanel
            let outcome: (
                handled: Bool,
                enabled: Bool,
                phase: String,
                selected: Bool,
                editCount: Int,
                error: String?
            )? = v2AwaitCallback(timeout: 10) { finish in
                Task { @MainActor in
                    let controller = panel.designModeController
                    let handled: Bool
                    if statusOnly {
                        handled = true
                    } else if mode == "enable" {
                        handled = await controller.setEnabled(true, reason: "cli.designMode")
                    } else if mode == "disable" {
                        handled = await controller.setEnabled(false, reason: "cli.designMode")
                    } else {
                        handled = await controller.toggle(reason: "cli.designMode")
                    }
                    finish((
                        handled,
                        controller.isActive,
                        controller.phase.commandValue,
                        controller.snapshot?.selection != nil,
                        controller.snapshot?.edits.count ?? 0,
                        controller.errorMessage
                    ))
                }
            }
            guard let outcome else {
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.browser.designMode.timeout",
                        defaultValue: "Timed out updating browser design mode"
                    ),
                    data: nil
                )
            }
            return .ok(v2BrowserPanelFields(context, adding: [
                "handled": outcome.handled,
                "enabled": outcome.enabled,
                "phase": outcome.phase,
                "selected": outcome.selected,
                "edit_count": outcome.editCount,
                "error": v2OrNull(outcome.error),
            ]))
        }
    }
}
