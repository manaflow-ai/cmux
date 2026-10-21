import Foundation

extension AgentPaneScrollAnchors {
    /// `chat.scrollAnchor {sessionId, rowId or null, offset}` and `chat.scrollAnchor.get
    /// {sessionId}` on the pane's own host (``AgentPaneBridge``), where an agent pane's page talks
    /// unless `agent.pageHost` is on — which it is not by default, so this is the path a reader is
    /// on (cx-6bgzj).
    ///
    /// This is what that host does with them today, written down so a test can hold it: nothing
    /// has a route for either, so `AgentPaneRequest` decodes both as `.unsupported` and the model
    /// refuses them. The page swallows that (`fetchScrollAnchor` catches to null,
    /// `postScrollAnchor` catches), so no place is ever kept and every chat reopens at its latest
    /// message. The next commit answers them from the store instead.
    static func reply(to method: String, params: [String: Any]?) -> [String: Any] {
        _ = params
        return AgentPaneReply.failure(code: "unsupported", message: "Unsupported request: \(method)")
    }
}
