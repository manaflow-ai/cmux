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
    private static let observedNotificationMethods = [
        "_acpmux/prompt_accepted", "_acpmux/event", "_acpmux/permission_pending",
    ]
    private static let eventObserverMarkers = [
        "\"permission_request\"", "\"permission_reissued\"", "\"permission_decision\"",
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
    func toPage(_ text: String) -> Inbound {
        switch AcpmuxJSONKeys.verdict(text) {
        case .clean: break
        case .malformed: return .drop
        case .duplicate: return .close
        }
        // Stream notifications have no id to rewrite. The marker check avoids Foundation's full
        // parse for the usual `session/update` payloads while retaining the parsed object for the
        // three notifications read by host observers.
        let methodScan = Self.topLevelMethod(text)
        var method = methodScan.value
        var notificationObject: [String: Any]?
        // JSON method names are normally plain ASCII. If an escaped key or value appears, use
        // Foundation once to decode that rare spelling before deciding whether host observers
        // need the object; plain stream notifications never take this path.
        if method?.contains("\\") == true || (!methodScan.found && text.contains("\\")) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               let decoded = object["method"] as? String {
                method = decoded
                notificationObject = object
            }
        }
        if let method, Self.observedNotificationMethods.contains(method) {
            // Most `_acpmux/event` frames are transcript chunks. The host only reads permission
            // records from that stream; pacing for turn boundaries uses the raw text path below.
            if method == "_acpmux/event" &&
                !Self.eventObserverMarkers.contains(where: text.contains) {
                return .page(text, object: nil, replyTo: "_acpmux/event")
            }
            let object = notificationObject ?? (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            guard let object
            else { return .page(text, object: nil, replyTo: nil) }
            if method == "_acpmux/prompt_accepted", let promptAccepted,
               let promptId = (object["params"] as? [String: Any])?["promptId"] as? String {
                promptAccepted(promptId)
            }
            return .page(text, object: object, replyTo: method)
        }
        if methodScan.found {
            return .page(text, object: nil, replyTo: nil)
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .drop }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }) else { return .drop }
        state.withLock { $0.answered.removeValue(forKey: relayID) }?(object["error"] == nil && object["result"] != nil)
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

    /// Finds the top-level `method` key and value without constructing a JSON object. The duplicate-key
    /// validator has already established that this is well-formed JSON, so this small scanner only
    /// needs to track strings and nesting; it avoids mistaking a transcript field named `method`
    /// for the frame's method when deciding whether a reply needs a full parse.
    private struct MethodScan {
        var found: Bool
        var value: String?
    }

    private static func topLevelMethod(_ text: String) -> MethodScan {
        var text = text
        return text.withUTF8 { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return MethodScan(found: false, value: nil) }
            var depth = 0
            var i = 0
            while i < bytes.count {
                switch base[i] {
                case 0x22: // string
                    let start = i + 1
                    i = start
                    var escaped = false
                    while i < bytes.count {
                        let byte = base[i]
                        if escaped { escaped = false }
                        else if byte == 0x5C { escaped = true }
                        else if byte == 0x22 { break }
                        i += 1
                    }
                    if depth == 1, i - start == 6 {
                        var next = i + 1
                        while next < bytes.count, base[next] == 0x20 || base[next] == 0x09 || base[next] == 0x0A || base[next] == 0x0D { next += 1 }
                        if next < bytes.count, base[next] == 0x3A,
                           base[start] == 0x6D, base[start + 1] == 0x65, base[start + 2] == 0x74,
                           base[start + 3] == 0x68, base[start + 4] == 0x6F, base[start + 5] == 0x64 {
                            var value = next + 1
                            while value < bytes.count, base[value] == 0x20 || base[value] == 0x09 || base[value] == 0x0A || base[value] == 0x0D { value += 1 }
                            guard value < bytes.count, base[value] == 0x22 else {
                                return MethodScan(found: true, value: nil)
                            }
                            let valueStart = value + 1
                            value = valueStart
                            var valueEscaped = false
                            while value < bytes.count {
                                let byte = base[value]
                                if valueEscaped { valueEscaped = false }
                                else if byte == 0x5C { valueEscaped = true }
                                else if byte == 0x22 { break }
                                value += 1
                            }
                            if valueEscaped || value >= bytes.count {
                                return MethodScan(found: true, value: nil)
                            }
                            return MethodScan(found: true, value: String(decoding: bytes[valueStart..<value], as: UTF8.self))
                        }
                    }
                    i += 1
                case 0x7B, 0x5B: depth += 1; i += 1
                case 0x7D, 0x5D: depth -= 1; i += 1
                default: i += 1
                }
            }
            return MethodScan(found: false, value: nil)
        }
    }
}
