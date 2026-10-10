import Foundation
import Synchronization

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
    }

    private nonisolated struct State {
        var next = 1
        var entries: [Int: Entry] = [:]
        var inFlight: Set<String> = []
    }

    private let state = Mutex(State())

    /// The relay id for a page request with raw id `pageID`; nil while that page id is in flight.
    func begin(pageID: String, method: String) -> Int? {
        state.withLock { state in
            guard !state.inFlight.contains(pageID) else { return nil }
            let id = state.next
            state.next += 1
            state.inFlight.insert(pageID)
            state.entries[id] = Entry(pageID: pageID, method: method)
            return id
        }
    }

    /// The request was not sent after all.
    func cancel(_ id: Int) {
        state.withLock { state in
            if let entry = state.entries.removeValue(forKey: id) { state.inFlight.remove(entry.pageID) }
        }
    }

    /// What the socket does with one daemon frame.
    nonisolated enum Inbound {
        /// To the page: the fresh serialization, the parsed frame (its id the page's) for the
        /// observers, and the request a reply answers.
        case page(String, object: [String: Any], replyTo: String?)
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
            guard let fresh = Self.encode(object) else { return .drop }
            return .page(fresh, object: object, replyTo: nil)
        }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }),
              let entry = state.withLock({ state -> Entry? in
                  guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
                  state.inFlight.remove(entry.pageID)
                  return entry
              }), let id = Self.value(entry.pageID) else { return .drop }
        object["id"] = id
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
