import Foundation

extension Workspace {
    /// The `initialEnvironmentOverrides` a terminal restored from `terminal` starts with, so a pane
    /// switched to another Claude account keeps it after a relaunch (spec D9). It applies the
    /// switch's own rule to the current workspace and app environment: each account value as
    /// switched, and `""` only for a cleared key one of those environments would supply. Empty for
    /// a pane that never switched.
    func restoredClaudeAccountEnvironmentOverrides(_ terminal: SessionTerminalPanelSnapshot?) -> [String: String] {
        guard let account = terminal?.claudeAccountEnvironment else { return [:] }
        return ClaudeAccountSwitchSurfaceEnvironment(
            accountEnvironment: account.accountEnvironment,
            workspaceEnvironment: workspaceEnvironment,
            processEnvironment: ProcessInfo.processInfo.environment
        ).overrides
    }

    /// The restore's startup `input` with the account keys the pane cleared unset, when it runs
    /// cmux's restore verb (see ``ClaudeAccountPaneEnvironment/restoreStartupInput(_:)``).
    func restoredClaudeAccountStartupInput(_ input: String, _ terminal: SessionTerminalPanelSnapshot?) -> String {
        terminal?.claudeAccountEnvironment?.restoreStartupInput(input) ?? input
    }
}
