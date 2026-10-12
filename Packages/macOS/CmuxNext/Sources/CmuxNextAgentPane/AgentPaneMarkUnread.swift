import Foundation

/// Mark as Unread (cx-ncc.78, Codex parity): acpmux keeps a pane's chat unread until it is hidden
/// and shown again. The chat menu's row (`chat.markUnread`) and the tab's Mark Tab as Unread both
/// land here.
public struct AgentPaneMarkUnread {
    let model: AgentPaneModel

    public init(_ model: AgentPaneModel) { self.model = model }

    /// False when the pane shows no chat or acpmux refuses.
    public func run() async -> Bool {
        guard let sessionId = model.sessionId, model.newTab == nil else { return false }
        return (try? await model.transport.markUnread(sessionId)) != nil
    }

    func reply() async -> [String: Any] {
        await run() ? AgentPaneReply.success()
            : AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.markUnread")
    }
}
