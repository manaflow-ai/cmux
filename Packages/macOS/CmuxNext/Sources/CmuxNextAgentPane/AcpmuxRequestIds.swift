import Foundation
import Synchronization

/// Request ids between the page and acpmux (ad349, round 6). Every request the relay forwards gets
/// an id the relay owns (a counter per connection), so a page cannot make two requests share an
/// id at the daemon. The reply's id is mapped back to the page's, and a reply to a filtered method
/// (``AcpmuxPaneMethods/replyShapes``) is cut to its shape. A page id (JSON value and type) is used
/// by one request at a time. A daemon reply with an id the relay did not send is dropped;
/// daemon requests and notifications pass as they are.
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

    /// A daemon frame for the page; nil drops it.
    func toPage(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        let relayID: Int?
        if let scan = AcpmuxEnvelope.scan(bytes) {
            if scan.hasMethod { return text }
            relayID = scan.id.flatMap { Int(String(decoding: bytes[$0], as: UTF8.self)) }
        } else {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
            if object["method"] != nil { return text }
            relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap { Int($0) }
        }
        guard let relayID, let entry = state.withLock({ state -> Entry? in
            guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
            state.inFlight.remove(entry.pageID)
            return entry
        }) else { return nil }
        if let shape = AcpmuxPaneMethods.replyShapes[entry.method] {
            return AcpmuxPaneMethods.filteredReply(text, shape: shape, pageID: entry.pageID)
        }
        return Self.withID(entry.pageID, in: text)
    }

    /// `text` (one JSON object) with its top-level `id` replaced by the raw JSON `id`.
    static func withID(_ id: String, in text: String) -> String? {
        let bytes = Array(text.utf8)
        if let range = AcpmuxEnvelope.scan(bytes)?.id {
            var spliced = Array(bytes[..<range.lowerBound])
            spliced.append(contentsOf: id.utf8)
            spliced.append(contentsOf: bytes[range.upperBound...])
            return String(decoding: spliced, as: UTF8.self)
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let value = try? JSONSerialization.jsonObject(with: Data(id.utf8), options: [.fragmentsAllowed]),
              object["id"] != nil else { return nil }
        object["id"] = value
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The top level of one JSON object, read without parsing its values: where the `id` value is,
/// and whether there is a `method`. Nil when the text is not one plain object, or a top-level key
/// is escaped or repeated (the caller then parses the whole frame).
nonisolated enum AcpmuxEnvelope {
    nonisolated struct Scan {
        var id: Range<Int>?
        var hasMethod: Bool
    }

    static func scan(_ bytes: [UInt8]) -> Scan? {
        var reader = Reader(bytes: bytes)
        return reader.object()
    }

    private nonisolated struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func space() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        /// A string at `i` (a quote); `escaped` is set when it has a backslash.
        mutating func string(_ escaped: inout Bool) -> Bool {
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case 0x5C: escaped = true; i += 2
                case 0x22: i += 1; return true
                default: i += 1
                }
            }
            return false
        }

        mutating func value() -> Bool {
            guard i < bytes.count else { return false }
            switch bytes[i] {
            case 0x22:
                var escaped = false
                return string(&escaped)
            case 0x7B, 0x5B:
                var depth = 0
                while i < bytes.count {
                    switch bytes[i] {
                    case 0x22:
                        var escaped = false
                        guard string(&escaped) else { return false }
                        continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:
                let start = i
                while i < bytes.count, ![0x2C, 0x7D, 0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
                return i > start
            }
        }

        mutating func object() -> Scan? {
            space()
            guard i < bytes.count, bytes[i] == 0x7B else { return nil }
            i += 1
            var scan = Scan(id: nil, hasMethod: false)
            space()
            if i < bytes.count, bytes[i] == 0x7D { return scan }
            // Every member moves `i` forward, so the input's end ends the loop.
            while i < bytes.count {
                space()
                guard i < bytes.count, bytes[i] == 0x22 else { return nil }
                let keyStart = i + 1
                var escaped = false
                guard string(&escaped), !escaped else { return nil }
                let key = bytes[keyStart..<(i - 1)]
                space()
                guard i < bytes.count, bytes[i] == 0x3A else { return nil }
                i += 1
                space()
                let valueStart = i
                guard value() else { return nil }
                if key.elementsEqual("id".utf8) {
                    guard scan.id == nil else { return nil }
                    scan.id = valueStart..<i
                } else if key.elementsEqual("method".utf8) {
                    guard !scan.hasMethod else { return nil }
                    scan.hasMethod = true
                }
                space()
                guard i < bytes.count else { return nil }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x7D { return scan }
                return nil
            }
            return nil
        }
    }
}
