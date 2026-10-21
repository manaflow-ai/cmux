import CmuxNextSettings
import Foundation

extension AgentPaneTailCache {
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
        shared.remember(params?["tail"].flatMap { JSONValue(foundation: $0) }, for: session)
        return AgentPaneReply.success()
    }
}
