import Foundation
import CmuxNextCompat

/// Request ids between the page and acpmux (ad349, round 6). Every request the relay forwards gets
/// an id the relay owns (a counter per connection), so a page cannot make two requests share an
/// id at the daemon. The reply's id is mapped back to the page's, and a reply to a filtered method
/// (``AcpmuxPaneMethods/replyShapes``) is cut to its shape. A page id (JSON value and type) is used
/// by one request at a time. A daemon reply with an id the relay did not send is dropped. Every
/// daemon frame passes the duplicate-key check and reaches the page as a fresh serialization, as
/// every page frame reaches the daemon (in the transport).
nonisolated final class AcpmuxRequestIds: Sendable {
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
        var answered: [Int: @Sendable () -> Void] = [:]
        var hostIDs: Set<Int> = []
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
        state.withLock { $0.answered[id] = handler }
    }

    /// An id for a request the host sends itself (the person proof): its reply matches no page
    /// request, so it never reaches the page.
    func hostID() -> Int {
        state.withLock { state in
            let id = state.next
            state.next += 1
            state.hostIDs.insert(id)
            return id
        }
    }

    /// Whether an inbound response id belongs to a host-owned control call.
    func isHost(_ id: Int) -> Bool { state.withLock { $0.hostIDs.remove(id) != nil } }

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

    /// What the socket does with one daemon frame.
    nonisolated enum Inbound {
        /// To the page: the fresh serialization, the parsed frame (its id the page's) for the
        /// observers, and the request a reply answers.
        case page(String, object: [String: Any], replyTo: String?)
        /// A reply in place that acpmux answered: the host finishes it (``AgentPaneAgentReply``);
        /// acpmux's answer never reaches the page as it is.
        case complete(object: [String: Any], pageID: String, subject: String?)
        case drop
        /// A duplicate key: two parsers could read the frame differently, so the socket closes.
        case close
    }

    /// One daemon frame (ad349, round 8): the duplicate-key check, one full parse, then a fresh
    /// serialization; a reply gets the page's id (or its filtered shape). A reply to no request the
    /// relay sent is dropped.
    func toPage(_ text: String) -> Inbound {
        switch AcpmuxJSONKeys.verdict(text) {
        case .clean: break
        case .malformed: return .drop
        case .duplicate: return .close
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .drop }
        if object["method"] != nil {
            if object["method"] as? String == "_acpmux/prompt_accepted", let promptAccepted,
               let promptId = (object["params"] as? [String: Any])?["promptId"] as? String {
                promptAccepted(promptId)
            }
            guard let fresh = Self.encode(object) else { return .drop }
            return .page(fresh, object: object, replyTo: nil)
        }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }) else { return .drop }
        state.withLock { $0.answered.removeValue(forKey: relayID) }?()
        guard let entry = state.withLock({ state -> Entry? in
            guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
            state.inFlight.remove(entry.pageID)
            return entry
        }), let id = Self.value(entry.pageID) else { return .drop }
        object["id"] = id
        // The page id is free again from here, while the host still sends the reply: the page
        // never reuses an id (direct.ts counts them up), so its answer cannot go to another request.
        if entry.method == AgentPaneAgentReply.method {
            return .complete(object: object, pageID: entry.pageID, subject: entry.subject)
        }
        if let shape = AcpmuxPaneMethods.replyShapes[entry.method] {
            return .page(AcpmuxPaneMethods.filteredReply(object, shape: shape, pageID: entry.pageID), object: object, replyTo: entry.method)
        }
        guard let fresh = Self.encode(object) else { return .drop }
        return .page(fresh, object: object, replyTo: entry.method)
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
