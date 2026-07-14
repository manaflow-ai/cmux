import Foundation

extension TerminalController {
    func sendDesignModePrompt(_ prompt: String, in workspace: Workspace) throws {
        guard let service = agentChatTranscriptService,
              let terminal = service.sessionRecords(workspaceID: nil).lazy.compactMap({ record -> TerminalPanel? in
                  guard record.state != .ended,
                        let surfaceID = record.surfaceID,
                        service.registry.liveSession(surfaceID: surfaceID)?.sessionID == record.sessionID,
                        let surfaceUUID = UUID(uuidString: surfaceID) else { return nil }
                  return workspace.terminalPanel(for: surfaceUUID)
              }).first else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        guard terminal.sendText(prompt) else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        guard terminal.sendNamedKeyResult("return").accepted else {
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
