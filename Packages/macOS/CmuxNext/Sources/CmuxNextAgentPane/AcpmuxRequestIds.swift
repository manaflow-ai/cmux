import Foundation
import Synchronization

/// Request ids between the page and acpmux (ad349, round 6). Every request the relay forwards gets
/// an id the relay owns (a counter per connection), so a page cannot make two requests share an
/// id at the daemon. The reply's id is mapped back to the page's, and a reply to a filtered method
/// (``AcpmuxPaneMethods/replyShapes``) is cut to its shape. A page id (JSON value and type) is used
/// by one request at a time. A daemon reply with an id the relay did not send is dropped, and a
/// daemon request or notification passes to the page as it is. A reply is parsed in full and
/// serialized again; so is every page frame (in the transport): one parser, and no page bytes
/// reach the daemon as they are.
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

    /// A daemon frame for the page; nil drops it. One full parse (the same parser that reads every
    /// page frame): no second parser on this path to read a duplicate or escaped key differently.
    func toPage(_ text: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        if object["method"] != nil { return text }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }),
              let entry = state.withLock({ state -> Entry? in
                  guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
                  state.inFlight.remove(entry.pageID)
                  return entry
              }) else { return nil }
        if let shape = AcpmuxPaneMethods.replyShapes[entry.method] {
            return AcpmuxPaneMethods.filteredReply(object, shape: shape, pageID: entry.pageID)
        }
        guard let id = Self.value(entry.pageID) else { return nil }
        object["id"] = id
        return Self.encode(object)
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
