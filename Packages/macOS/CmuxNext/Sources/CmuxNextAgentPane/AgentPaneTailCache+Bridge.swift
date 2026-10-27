import Foundation

extension AgentPaneTailCache {
    /// The ops this seam answers, which is what ``AgentPageProvider`` branches on. Named rather than
    /// matched by prefix, for the reason `AgentPaneScrollAnchors.handles` gives: anything that is not
    /// `.get` is a write, so a later `chat.tail.forget` would have erased a chat's tail instead of
    /// being refused.
    static func handles(method: String) -> Bool {
        method == "chat.tail" || method == "chat.tail.get"
    }
}
