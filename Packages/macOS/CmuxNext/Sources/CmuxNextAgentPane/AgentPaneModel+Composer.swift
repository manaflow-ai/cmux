extension AgentPaneModel {
    /// `pane.showContextUsage`: writes the setting through ``onShowContextUsage``.
    func showContextUsage(_ show: Bool) async -> [String: Any] {
        guard let onShowContextUsage else { return AgentPaneReply.failure(code: "unsupported", message: "Settings are unavailable") }
        do {
            try await onShowContextUsage(show)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "settings_write_failed", message: error.localizedDescription)
        }
    }
}
