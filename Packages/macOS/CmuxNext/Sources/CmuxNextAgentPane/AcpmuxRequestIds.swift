import Foundation
import CmuxNextCompat

/// Request ids between the page and acpmux (ad349, round 6). Every request the relay forwards gets
/// an id the relay owns (a counter per connection), so a page cannot make two requests share an
/// id at the daemon. The reply's id is mapped back to the page's, and a reply to a filtered method
/// (``AcpmuxPaneMethods/replyShapes``) is cut to its shape. A page id (JSON value and type) is used
/// by one request at a time. A daemon reply with an id the relay did not send is dropped. Replies
/// pass the duplicate-key check and reach the page as a fresh serialization. Notifications
/// have no id to rewrite, so the original text is forwarded after the duplicate-key check; only
/// notifications that feed a host-side observer are parsed.
nonisolated final class AcpmuxRequestIds: Sendable {
    /// Notifications a host observer reads (``toPage(_:)``); never shed (``AcpmuxPaneShedding``).
    static let observedNotificationMethods = [
        "_acpmux/prompt_accepted", "_acpmux/event", "_acpmux/permission_pending",
    ]
    /// The `_acpmux/event` kinds a host observer reads (``AcpmuxDecisionContexts``,
    /// ``AgentPaneUserGestures``: each reads `params.kind`); every other event goes on as its text.
    static let observedEventKinds: Set<String> = [
        "permission_request", "permission_reissued", "permission_decision",
    ]

    private nonisolated struct Entry {
        var pageID: String
        var method: String
        /// The chat a reply in place named (``AgentPaneAgentReply``).
        var subject: String?
    }

    private nonisolated struct State {
        var next = 1
        var entries: [Int: Entry] = [:]
        var inFlight: Set<String> = []
        /// Told when the daemon answers a relay id (``whenAnswered(_:_:)``).
        var answered: [Int: @Sendable (Bool) -> Void] = [:]
    }

    private let state = Mutex(State())
    /// Told the promptId of each `_acpmux/prompt_accepted` the daemon sends (``AgentPanePromptJournal``).
    private let promptAccepted: (@Sendable (String) -> Void)?

    init(promptAccepted: (@Sendable (String) -> Void)? = nil) {
        self.promptAccepted = promptAccepted
    }

    /// Calls `handler` (off the main thread) when the daemon answers request `id`, with a result
    /// or an error; never when the request is cancelled.
    func whenAnswered(_ id: Int, _ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.answered[id] = { _ in handler() } }
    }

    /// A host-owned request's acknowledgement, distinguishing a result from a refusal.
    func whenResult(_ id: Int, _ handler: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.answered[id] = handler }
    }

    /// An id for a request the host sends itself (the person proof): its reply matches no page
    /// request, so it never reaches the page.
    func hostID() -> Int {
        state.withLock { state in
            let id = state.next
            state.next += 1
            return id
        }
    }

    /// The relay id for a page request with raw id `pageID`; nil while that page id is in flight.
    /// `subject`: the chat a reply in place names (``AgentPaneAgentReply``).
    func begin(pageID: String, method: String, subject: String? = nil) -> Int? {
        state.withLock { state in
            guard !state.inFlight.contains(pageID) else { return nil }
            let id = state.next
            state.next += 1
            state.inFlight.insert(pageID)
            state.entries[id] = Entry(pageID: pageID, method: method, subject: subject)
            return id
        }
    }

    /// The request was not sent after all.
    func cancel(_ id: Int) {
        state.withLock { state in
            if let entry = state.entries.removeValue(forKey: id) { state.inFlight.remove(entry.pageID) }
            state.answered[id] = nil
        }
    }

    /// Cancels a host-owned request and wakes its waiter (used when a socket closes before a reply).
    func cancelAndNotify(_ id: Int) {
        let handler = state.withLock { state -> (@Sendable (Bool) -> Void)? in
            state.answered.removeValue(forKey: id)
        }
        handler?(false)
        cancel(id)
    }

    /// What the socket does with one daemon frame.
    nonisolated enum Inbound {
        /// To the page: the fresh serialization (or original notification text), an optional
        /// parsed frame for observers, and the request a reply answers.
        case page(String, object: [String: Any]?, replyTo: String?)
        /// A reply in place that acpmux answered: the host finishes it (``AgentPaneAgentReply``);
        /// acpmux's answer never reaches the page as it is.
        case complete(object: [String: Any], pageID: String, subject: String?)
        case drop
        /// A duplicate key: two parsers could read the frame differently, so the socket closes.
        case close
    }

    /// One daemon frame (ad349, round 8): the duplicate-key check, then one parse only when a
    /// notification feeds a host observer or when a reply needs its id rewritten. Notifications
    /// otherwise retain their original text; a reply gets the page's id (or its filtered shape).
    /// A reply to no request the relay sent is dropped.
    func toPage(_ text: String) -> Inbound { classify(text).inbound }

    /// ``toPage(_:)``, and whether the page waits on an opaque notification
    /// (``AcpmuxPaneSocket/pageWaits(method:kind:)``), all from one read of the frame
    /// (``AcpmuxJSONKeys/facts(_:)``): the check, the top-level `method` and `id`, and
    /// `params.kind`. Nothing searches the frame's text after it.
    func classify(_ text: String) -> (inbound: Inbound, waits: Bool) {
        let facts = AcpmuxJSONKeys.facts(text)
        switch facts.verdict {
        case .clean: break
        case .malformed: return (.drop, false)
        case .duplicate: return (.close, false)
        }
        if let method = facts.method, Self.observedNotificationMethods.contains(method) {
            // Most `_acpmux/event` frames are transcript chunks. The host only reads permission
            // records from that stream; a turn boundary wakes a hidden page by its kind alone.
            if method == "_acpmux/event", !(facts.kind.map(Self.observedEventKinds.contains) ?? false) {
                return (.page(text, object: nil, replyTo: "_acpmux/event"), AcpmuxPaneSocket.pageWaits(method: method, kind: facts.kind))
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { return (.page(text, object: nil, replyTo: nil), AcpmuxPaneSocket.pageWaits(method: method, kind: facts.kind)) }
            if method == "_acpmux/prompt_accepted", let promptAccepted,
               let promptId = (object["params"] as? [String: Any])?["promptId"] as? String {
                promptAccepted(promptId)
            }
            return (.page(text, object: object, replyTo: method), false)
        }
        if facts.hasMethod {
            return (.page(text, object: nil, replyTo: nil), AcpmuxPaneSocket.pageWaits(method: facts.method, kind: facts.kind))
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return (.drop, false) }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }) else { return (.drop, false) }
        state.withLock { $0.answered.removeValue(forKey: relayID) }?(object["error"] == nil && object["result"] != nil)
        guard let entry = state.withLock({ state -> Entry? in
            guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
            state.inFlight.remove(entry.pageID)
            return entry
        }), let id = Self.value(entry.pageID) else { return (.drop, false) }
        object["id"] = id
        // The page id is free again from here, while the host still sends the reply: the page
        // never reuses an id (direct.ts counts them up), so its answer cannot go to another request.
        if entry.method == AgentPaneAgentReply.method {
            return (.complete(object: object, pageID: entry.pageID, subject: entry.subject), false)
        }
        if let shape = AcpmuxPaneMethods.replyShapes[entry.method] {
            return (.page(AcpmuxPaneMethods.filteredReply(object, shape: shape, pageID: entry.pageID), object: object, replyTo: entry.method), false)
        }
        guard let fresh = Self.encode(object) else { return (.drop, false) }
        return (.page(fresh, object: object, replyTo: entry.method), false)
    }

    /// A raw JSON id back to its value.
    static func value(_ raw: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
