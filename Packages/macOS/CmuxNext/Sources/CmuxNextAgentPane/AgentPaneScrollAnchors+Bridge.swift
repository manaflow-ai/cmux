import Foundation

extension AgentPaneScrollAnchors {
    /// `chat.scrollAnchor {sessionId, rowId or null, offset}` and `chat.scrollAnchor.get
    /// {sessionId}` from the pane's own host (``AgentPaneBridge``), which hands bridged Foundation
    /// values over: the same two ops `AgentPageProvider+Scroll` serves on the shared page host,
    /// from this one store.
    ///
    /// Both hosts need them because `agent.pageHost` is off by default, so an agent pane's page
    /// talks to the pane's own host, and `callNative` sends these there (cx-6bgzj). Served on only
    /// one path, a chat would reopen at its latest message for everyone with the setting off.
    ///
    /// A chat's place is the chat's, not the pane's, so ``AgentPaneModel`` never sees these, as
    /// with `chat.tail`.
    /// The ops this seam answers, which is what ``AgentPaneBridge`` branches on. Named rather than
    /// matched by prefix so a later `chat.scrollAnchor…` op added to ``AgentPaneRequest`` reaches
    /// the model instead of being swallowed here.
    static func handles(method: String) -> Bool {
        method == "chat.scrollAnchor" || method == "chat.scrollAnchor.get"
    }

    static func reply(to method: String, params: [String: Any]?) -> [String: Any] {
        guard let session = params?["sessionId"] as? String, !session.isEmpty else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "A chat's place needs a sessionId")
        }
        // No store (a test host, the gallery): nothing is kept, and nothing is answered.
        guard let anchors = shared else { return AgentPaneReply.success() }
        if method == "chat.scrollAnchor.get" {
            guard let anchor = anchors.anchor(for: session) else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["rowId": anchor.rowId, "offset": anchor.offset])
        }
        guard method == "chat.scrollAnchor" else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "No such chat place request")
        }
        // At the latest message the page sends `rowId: null`, which forgets the place.
        let row = params?["rowId"] as? String
        let offset = (params?["offset"] as? NSNumber)?.doubleValue ?? 0
        anchors.remember(row.map { AgentPaneScrollAnchor(rowId: $0, offset: offset) }, for: session)
        return AgentPaneReply.success()
    }
}
