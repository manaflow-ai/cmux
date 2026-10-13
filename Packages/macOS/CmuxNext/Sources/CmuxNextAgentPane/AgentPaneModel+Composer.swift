extension AgentPaneModel {
    /// `pane.showContextUsage`/`pane.showDictation`: writes the composer flag at `path` through
    /// ``onComposerSetting``; with no writer the page keeps its own choice.
    func setComposer(_ path: [String], _ show: Bool) async -> [String: Any] {
        guard let onComposerSetting else { return AgentPaneReply.failure(code: "unsupported", message: "Settings are unavailable") }
        do {
            try await onComposerSetting(path, show)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "settings_write_failed", message: error.localizedDescription)
        }
    }
}
