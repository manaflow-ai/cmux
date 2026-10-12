import Foundation

/// Mark as Unread (cx-ncc.78, Codex parity): acpmux keeps a pane's chat unread until it is hidden
/// and shown again. The chat menu's row (`chat.markUnread`) and the tab's Mark Tab as Unread both
/// land here.
public enum AgentPaneMarkUnread {
    /// False when the pane shows no chat or acpmux refuses.
    public static func run(_ model: AgentPaneModel) async -> Bool {
        guard let sessionId = model.sessionId, model.newTab == nil else { return false }
        return (try? await model.transport.markUnread(sessionId)) != nil
    }

    static func reply(_ model: AgentPaneModel) async -> [String: Any] {
        await run(model) ? AgentPaneReply.success()
            : AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.markUnread")
    }
}
