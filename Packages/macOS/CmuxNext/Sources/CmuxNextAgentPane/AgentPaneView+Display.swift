public import CmuxNextSettings

/// The chat's look (``AgentPaneDisplaySetting``: `agentPane.display.*` and the Markdown viewer keys it
/// follows) reaches the page as the `display` event, read by the page's chatDisplay.ts.
extension AgentPageEvent {
    /// The accepted look values by dotted key.
    public static func display(_ display: AgentPaneDisplaySetting) -> AgentPageEvent {
        AgentPageEvent(kind: "display", value: display.pageValue)
    }
}

extension AgentPaneView {
    /// Gives the page the chat's look (a change only); the model keeps it for a new page.
    public func pushDisplay(_ display: AgentPaneDisplaySetting) {
        guard display != model.display else { return }
        model.display = display
        deliver([.display(display)])
    }
}

extension AgentPaneModel {
    /// `pane.setDisplay {key, value}`: the ··· menu's Text & Width popover writes one
    /// `agentPane.display.*` key through ``onDisplaySetting``; a null value removes it.
    func setDisplay(_ path: [String], _ value: JSONValue?) async -> [String: Any] {
        guard let onDisplaySetting else { return AgentPaneReply.failure(code: "unsupported", message: "Settings are unavailable") }
        do {
            try await onDisplaySetting(path, value)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "settings_write_failed", message: error.localizedDescription)
        }
    }
}
