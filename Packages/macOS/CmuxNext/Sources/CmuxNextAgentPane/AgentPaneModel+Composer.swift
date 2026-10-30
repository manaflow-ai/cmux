import CmuxNextSettings

extension AgentPaneModel {
    /// `pane.showContextUsage`/`pane.showDictation`/`pane.setScrollToBottomOnSend`: writes the composer flag at `path` through
    /// ``onComposerSetting``; with no writer the page keeps its own choice.
    func setComposer(_ path: [String], _ show: Bool, userGesture: Bool = false) async -> [String: Any] {
        guard let onComposerSetting else { return AgentPaneReply.failure(code: "unsupported", message: "Settings are unavailable") }
        // The legacy WKWebView bridge has no PageCallContext.userGesture. Do not let a trusted
        // page script turn a user-only preference into an arbitrary `.user` settings write.
        if path == AgentPaneComposerSetting.scrollToBottomOnSendPath,
           !userGesture, !transport.gestures.consume() {
            return Self.transportFailure(.gestureRequired)
        }
        do {
            try await onComposerSetting(path, show)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "settings_write_failed", message: error.localizedDescription)
        }
    }
}
