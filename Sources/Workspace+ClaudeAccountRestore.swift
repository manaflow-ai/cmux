import Foundation

extension Workspace {
    /// The `initialEnvironmentOverrides` a terminal restored from `terminal` starts with, so a pane
    /// switched to another Claude account keeps it after a relaunch (spec D9). It applies the
    /// switch's own rule to the current workspace and app environment: each account value as
    /// switched, and `""` only for a cleared key one of those environments would supply. Empty for
    /// a pane that never switched.
    func restoredClaudeAccountEnvironmentOverrides(_ terminal: SessionTerminalPanelSnapshot?) -> [String: String] {
        claudeAccountSurfaceEnvironment(terminal?.claudeAccountEnvironment)?.overrides ?? [:]
    }

    /// What `account` gives a new surface in this workspace now (see
    /// ``ClaudeAccountPaneEnvironment/surfaceEnvironment(workspaceEnvironment:processEnvironment:)``),
    /// or `nil` for a pane that never switched. A relaunch restore and a plain respawn share it, so
    /// a pane keeps its account the same way through both, whatever the workspace supplies by then.
    func claudeAccountSurfaceEnvironment(_ account: ClaudeAccountPaneEnvironment?) -> ClaudeAccountSwitchSurfaceEnvironment? {
        account?.surfaceEnvironment(workspaceEnvironment: workspaceEnvironment)
    }

    /// The restore's startup `input` with the account keys the pane cleared unset, when it runs
    /// cmux's restore verb (see ``ClaudeAccountPaneEnvironment/restoreStartupInput(_:)``).
    func restoredClaudeAccountStartupInput(_ input: String, _ terminal: SessionTerminalPanelSnapshot?) -> String {
        terminal?.claudeAccountEnvironment?.restoreStartupInput(input) ?? input
    }
}
