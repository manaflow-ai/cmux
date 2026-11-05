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

    /// The same memory read, with a disk-copy miss forwarded to the pane's host. The daemon
    /// owns persistence and the web page interprets its envelope; neither policy lives here.
    static func reply(to method: String, params: [String: Any]?, host: (any AgentPaneHostProviding)?, pageGeneration: UInt64? = nil) async -> [String: Any] {
        // A surviving page can still hold the previous account's JS tail after resume().
        // Its immutable provider generation fences writes; fresh reads still use this lifecycle.
        if method == "chat.tail", let pageGeneration, pageGeneration != shared.generation {
            return AgentPaneReply.success()
        }
        let generation = shared.generation
        guard shared.acceptsTails else { return reply(to: method, params: params) }
        guard method == "chat.tail.get", let session = params?["sessionId"] as? String, !session.isEmpty,
              shared.tail(for: session) == nil else { return reply(to: method, params: params) }
        let data = await host?.peerSnapshot(sessionId: session)
        // clear() runs on this actor too: a reply from before sign-out cannot cross it,
        // even if a new sign-in already resumed reads while the socket was answering.
        guard shared.generation == generation else { return AgentPaneReply.success(NSNull()) }
        if shared.tail(for: session) == nil, let data, let value = try? JSONSerialization.jsonObject(with: data) {
            return AgentPaneReply.success(value)
        }
        return reply(to: method, params: params)
    }

    /// The chat's tail a `chat.subagentPane` carries (`handOver {sessionId, tail}`, subagentPanes.ts),
    /// kept as `chat.tail` keeps it, in the request's own turn on either host and before the pane's
    /// open reads the store (``AgentPaneSpareReadiness``): a `chat.tail` of its own was never
    /// awaited, so it could land after that read and the pane opened cold (#36650). A page from
    /// before a sign-out (`pageGeneration`) hands nothing over, as its `chat.tail` writes nothing.
    static func keepHandOver(of method: String, params: [String: Any]?, pageGeneration: UInt64) {
        guard method == "chat.subagentPane", let handOver = params?["handOver"] as? [String: Any],
              handOver["tail"] != nil, pageGeneration == shared.generation else { return }
        _ = reply(to: "chat.tail", params: handOver)
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
