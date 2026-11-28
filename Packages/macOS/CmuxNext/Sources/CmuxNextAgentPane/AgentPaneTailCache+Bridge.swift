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

    /// What a tail op answers: its value, or why it is refused (`native.invalid_request`).
    enum Answer: Equatable {
        case value(JSONValue)
        case refused(String)

        /// The answer as the pane bridge replies it: the one Foundation walk, at the WebKit edge.
        var reply: [String: Any] {
            switch self {
            case .value(let value): AgentPaneReply.success(value.foundationObject)
            case .refused(let message): AgentPaneReply.failure(code: AgentPaneTailCache.refusedCode, message: message)
            }
        }
    }

    static let refusedCode = "native.invalid_request"

    /// The same memory read; a miss reads the disk tier (``AgentPaneTailDisk``), and a miss there is
    /// forwarded to the pane's host for a peer chat's disk copy. The daemon
    /// owns persistence and the web page interprets its envelope; neither policy lives here.
    ///
    /// In ``JSONValue`` end to end: the tail is the chat's whole last read (thousands of events),
    /// and walking it into Foundation and back on the main actor hung the app 26 s (cmuxterm-hq#19028).
    static func answer(to method: String, params: JSONValue, host: (any AgentPaneHostProviding)?, pageGeneration: UInt64? = nil) async -> Answer {
        // A surviving page can still hold the previous account's JS tail after resume().
        // Its immutable provider generation fences writes; fresh reads still use this lifecycle.
        if method == "chat.tail", let pageGeneration, pageGeneration != shared.generation {
            return .value(.null)
        }
        let generation = shared.generation
        guard shared.acceptsTails else { return answer(to: method, params: params) }
        guard method == "chat.tail.get", case .string(let session)? = params["sessionId"], !session.isEmpty,
              shared.tail(for: session) == nil else { return answer(to: method, params: params) }
        // The disk tier first: this Mac's own copy of what a page last read, local chats included.
        if let kept = await shared.diskTail(for: session) {
            guard shared.generation == generation else { return .value(.null) }
            return .value(kept)
        }
        guard shared.generation == generation else { return .value(.null) }
        let data = await host?.peerSnapshot(sessionId: session)
        // clear() runs on this actor too: a reply from before sign-out cannot cross it,
        // even if a new sign-in already resumed reads while the socket was answering.
        guard shared.generation == generation else { return .value(.null) }
        if shared.tail(for: session) == nil, let data, let value = try? JSONValue.parse(data) {
            return .value(value)
        }
        return answer(to: method, params: params)
    }

    /// ``answer(to:params:host:pageGeneration:)`` for the pane's own host (``AgentPaneBridge``),
    /// which hands bridged Foundation values over and replies them.
    static func reply(to method: String, params: [String: Any]?, host: (any AgentPaneHostProviding)?, pageGeneration: UInt64? = nil) async -> [String: Any] {
        await answer(to: method, params: json(params), host: host, pageGeneration: pageGeneration).reply
    }

    /// The chat's tail a `chat.subagentPane` carries (`handOver {sessionId, tail}`, subagentPanes.ts),
    /// kept as `chat.tail` keeps it, in the request's own turn on either host and before the pane's
    /// open reads the store (``AgentPaneSpareReadiness``): a `chat.tail` of its own was never
    /// awaited, so it could land after that read and the pane opened cold (#36650). A page from
    /// before a sign-out (`pageGeneration`) hands nothing over, as its `chat.tail` writes nothing.
    static func keepHandOver(of method: String, params: JSONValue, pageGeneration: UInt64) {
        guard method == "chat.subagentPane", case .object(let handOver)? = params["handOver"],
              handOver["tail"] != nil, pageGeneration == shared.generation else { return }
        _ = answer(to: "chat.tail", params: .object(handOver))
    }

    /// ``keepHandOver(of:params:pageGeneration:)`` from the pane's own host's Foundation body.
    static func keepHandOver(of method: String, params: [String: Any]?, pageGeneration: UInt64) {
        guard method == "chat.subagentPane", let handOver = params?["handOver"] as? [String: Any],
              handOver["tail"] != nil, pageGeneration == shared.generation else { return }
        _ = answer(to: "chat.tail", params: json(handOver))
    }

    /// `chat.tail {sessionId, tail?}` and `chat.tail.get {sessionId}`: the memory store's answer,
    /// the same two ops on the pane's own host (``AgentPaneBridge``) and the shared page host
    /// (`AgentPageProvider+Tail`). New agent tabs are on the pane's own host unless `agent.pageHost`
    /// is on, so both hosts serve them, from this one store.
    ///
    /// A chat's tail is the chat's, not the pane's, so ``AgentPaneModel`` never sees these, as with
    /// `chat.scrollAnchor` on the page host.
    static func answer(to method: String, params: JSONValue) -> Answer {
        guard case .string(let session)? = params["sessionId"], !session.isEmpty else {
            return .refused("A chat tail needs a sessionId")
        }
        if method == "chat.tail.get" { return .value(shared.tail(for: session) ?? .null) }
        guard method == "chat.tail" else { return .refused("No such chat tail request") }
        let tail = params["tail"]
        if case .bool(true)? = params["ifNewer"] {
            if let tail { shared.rememberIfNewer(tail, for: session) }
        } else {
            shared.remember(tail, for: session)
        }
        return .value(.null)
    }

    /// ``answer(to:params:)`` from Foundation params, replied as Foundation.
    static func reply(to method: String, params: [String: Any]?) -> [String: Any] {
        answer(to: method, params: json(params)).reply
    }

    /// Bridged params as ``JSONValue``: the one walk in, which the store needs to keep a tail anyway.
    /// Member by member, as the Foundation path read them: a member that is not JSON is dropped
    /// alone, never taking `sessionId` or `tail` with it.
    private static func json(_ params: [String: Any]?) -> JSONValue {
        guard let params else { return .null }
        return .object(params.compactMapValues { JSONValue(foundation: $0) })
    }
}
