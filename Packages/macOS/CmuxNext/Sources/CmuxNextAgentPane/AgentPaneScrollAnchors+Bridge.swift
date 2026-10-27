import Foundation

extension AgentPaneScrollAnchors {
    /// The ops this seam answers, which is what ``AgentPageProvider`` branches on. Named rather than
    /// matched by prefix so a later `chat.scrollAnchor…` op reaches the model instead of being
    /// swallowed here.
    static func handles(method: String) -> Bool {
        method == "chat.scrollAnchor" || method == "chat.scrollAnchor.get"
    }
}
