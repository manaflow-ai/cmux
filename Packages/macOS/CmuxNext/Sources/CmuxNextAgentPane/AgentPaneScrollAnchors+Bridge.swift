import Foundation

extension AgentPaneBridge {
    /// This seam's reply to a page message, or nil when the message is not one of its ops and the
    /// model should see it. The whole of what ``AgentPaneBridge`` does for a chat's place, in one
    /// place a test can drive: a `WKScriptMessage` cannot be made outside WebKit, but this takes
    /// the same `message.body`. The handler is then one call, which
    /// `ChatScrollRestoreDefaultPathTests.theHandlerStillCallsThatSeam` holds in the source,
    /// because no test can send a message through the handler itself.
    static func chatPlaceReply(for body: Any) -> [String: Any]? {
        guard let object = body as? [String: Any], let method = object["method"] as? String,
              AgentPaneScrollAnchors.handles(method: method) else { return nil }
        return AgentPaneScrollAnchors.reply(to: method, params: object["params"] as? [String: Any])
    }
}

extension AgentPaneScrollAnchors {
    /// The ops this seam answers, which is what ``AgentPaneBridge`` branches on. Named rather than
    /// matched by prefix so a later `chat.scrollAnchor…` op added to ``AgentPaneRequest`` reaches
    /// the model instead of being swallowed here.
    static func handles(method: String) -> Bool {
        method == "chat.scrollAnchor" || method == "chat.scrollAnchor.get"
    }

    /// `chat.scrollAnchor {sessionId, rowId or null, offset}` and `chat.scrollAnchor.get
    /// {sessionId}` from the pane's own host (``AgentPaneBridge``), which hands bridged Foundation
    /// values over: the same two ops `AgentPageProvider+Scroll` serves on the shared page host,
    /// from this one store.
    ///
    /// Both hosts need them because `agent.pageHost` is off by default, so an agent pane's page
    /// talks to the pane's own host, and `callNative` sends these there (cx-6bgzj). Served on only
    /// one path, a chat would reopen at its latest message for everyone with the setting off.
    ///
    /// A chat's place is the chat's, not the pane's, so ``AgentPaneModel`` never sees these. The
    /// handler answers them before it decodes an `AgentPaneRequest` at all, the way it already
    /// answers the `popup.` ops above this branch.
    static func reply(to method: String, params: [String: Any]?) -> [String: Any] {
        // An op this seam does not serve, before anything else, so that a refusal never depends on
        // whether a store happens to exist — as it would if this came after the `shared` guard two
        // below. The one caller in the app, `chatPlaceReply`, already filters by `handles`, so
        // nothing reaches this today; it is here so that a second caller, or one that stops
        // filtering, is refused and not answered `ok`.
        guard handles(method: method) else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "No such chat place request")
        }
        guard let session = params?["sessionId"] as? String, !session.isEmpty else {
            return AgentPaneReply.failure(code: "native.invalid_request", message: "A chat's place needs a sessionId")
        }
        // No store (a test host, the gallery): nothing is kept, and nothing is answered.
        guard let anchors = shared else { return AgentPaneReply.success() }
        if method == "chat.scrollAnchor.get" {
            guard let anchor = anchors.anchor(for: session) else { return AgentPaneReply.success() }
            return AgentPaneReply.success(["rowId": anchor.rowId, "offset": anchor.offset])
        }
        // At the latest message the page sends `rowId: null`, which forgets the place.
        let row = params?["rowId"] as? String
        let offset = (params?["offset"] as? NSNumber)?.doubleValue ?? 0
        guard anchors.remember(row.map { AgentPaneScrollAnchor(rowId: $0, offset: offset) }, for: session) else {
            return AgentPaneReply.failure(code: "closed", message: "Closed")
        }
        return AgentPaneReply.success()
    }
}
