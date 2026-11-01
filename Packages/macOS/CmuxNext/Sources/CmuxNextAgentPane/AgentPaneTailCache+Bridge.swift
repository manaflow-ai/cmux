import CmuxNextSettings
import Foundation

extension AgentPaneTailCache {
    /// The ops this seam answers, which is what both hosts branch on. Named rather than matched by
    /// prefix, for the reason `AgentPaneScrollAnchors.handles` gives: ``reply(to:params:)`` treats
    /// anything that is not `.get` as a write, so a later `chat.tail.forget` would have erased a
    /// chat's tail instead of being refused, and on the pane's own host a prefix would swallow it
    /// before ``AgentPaneRequest`` could see it.
    static func handles(method: String) -> Bool {
        method == "chat.tail" || method == "chat.tail.get"
    }

    /// `chat.tail {sessionId, tail?}` and `chat.tail.get {sessionId}` from the pane's own host
    /// (``AgentPaneBridge``), which hands bridged Foundation values over: the same two ops the
    /// shared page host serves in `AgentPageProvider+Tail`. New agent tabs are on the pane's own
    /// host unless `agent.pageHost` is on, so both hosts serve them, from this one store.
    ///
    /// A chat's tail is the chat's, not the pane's, so ``AgentPaneModel`` never sees these, as with
    /// `chat.scrollAnchor` on the page host.
    static func reply(to method: String, params: [String: Any]?) -> [String: Any] {
        guard let session = params?["sessionId"] as? String, !session.isEmpty else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "A chat tail needs a sessionId")
        }
        if method == "chat.tail.get" {
            return AgentPaneReply.success(shared.tail(for: session)?.foundationObject ?? NSNull())
        }
        guard method == "chat.tail" else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "No such chat tail request")
        }
        let tail = params?["tail"].flatMap { JSONValue(foundation: $0) }
        if params?["ifNewer"] as? Bool == true {
            if let tail { shared.rememberIfNewer(tail, for: session) }
        } else {
            shared.remember(tail, for: session)
        }
        return AgentPaneReply.success()
    }
}
