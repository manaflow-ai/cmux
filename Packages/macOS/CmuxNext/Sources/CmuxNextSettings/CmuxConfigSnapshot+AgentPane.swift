/// The agent pane's settings: the edited-files card (`agentPane.editedFiles.*`) and the composer
/// (`agentPane.showContextUsage`).
nonisolated extension CmuxConfigSnapshot {
    /// Parses every agent pane key into `snapshot`.
    static func parseAgentPane(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.agentPaneEditedFiles = AgentPaneEditedFilesSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.agentPaneComposer = AgentPaneComposerSetting.parse(root, diagnostics: &snapshot.diagnostics)
    }
}
