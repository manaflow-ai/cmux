import Foundation

extension TerminalController {
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
            var cliTask: Task<Void, Never>?
            let outcome: (
                handled: Bool,
                enabled: Bool,
                phase: String,
                selected: Bool,
                editCount: Int,
                error: String?
            )? = v2AwaitCallback(timeout: 10) { finish in
                cliTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let controller = panel.designModeController
                    let handled: Bool
                    if statusOnly {
                        handled = true
                    } else if mode == "enable" {
                        handled = await panel.setDesignModeEnabled(true, reason: "cli.designMode")
                    } else if mode == "disable" {
                        handled = await panel.setDesignModeEnabled(false, reason: "cli.designMode")
                    } else {
                        handled = await panel.toggleDesignMode(reason: "cli.designMode")
                    }
                    guard !Task.isCancelled else { return }
                    finish((
                        handled,
                        controller.isActive,
                        controller.phase.commandValue,
                        controller.snapshot?.selections.isEmpty == false,
                        controller.snapshot?.edits.count ?? 0,
                        controller.errorMessage
                    ))
                }
            }
            guard let outcome else {
                cliTask?.cancel()
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.browser.designMode.timeout",
                        defaultValue: "Timed out updating browser design mode"
                    ),
                    data: nil
                )
            }
            if !statusOnly, !outcome.handled {
                return .err(
                    code: "design_mode_failed",
                    message: outcome.error ?? String(
                        localized: "cli.browser.designMode.updateFailed",
                        defaultValue: "Browser design mode could not be updated"
                    ),
                    data: v2BrowserPanelFields(context, adding: [
                        "enabled": outcome.enabled,
                        "phase": outcome.phase,
                        "selected": outcome.selected,
                        "edit_count": outcome.editCount,
                    ])
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
