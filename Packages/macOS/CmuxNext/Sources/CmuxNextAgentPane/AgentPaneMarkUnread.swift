import Foundation

/// Mark Tab as Unread (cx-ncc.78, Codex parity): acpmux keeps a pane's chat unread until it is
/// hidden and shown again. The chat menu's row sends `_acpmux/markUnread` itself (cx-jlzsf).
public struct AgentPaneMarkUnread {
    let model: AgentPaneModel

    public init(_ model: AgentPaneModel) { self.model = model }

    /// False when the pane shows no chat or acpmux refuses.
    public func run() async -> Bool {
        guard let sessionId = model.sessionId, model.newTab == nil else { return false }
        return (try? await model.transport.markUnread(sessionId)) != nil
    }
}
