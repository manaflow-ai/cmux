import Foundation
import CmuxNextCompat

/// Request ids between the page and acpmux (ad349, round 6). Every request the relay forwards gets
/// an id the relay owns (a counter per connection), so a page cannot make two requests share an
/// id at the daemon. The reply's id is mapped back to the page's, and a reply to a filtered method
/// (``AcpmuxPaneMethods/replyShapes``) is cut to its shape. A page id (JSON value and type) is used
/// by one request at a time. A daemon reply with an id the relay did not send is dropped. Replies
/// pass the duplicate-key check and reach the page as the daemon's text with the page's id spliced
/// in (a fresh serialization only when the id could not be found by the scan, or for a filtered
/// shape). Notifications have no id to rewrite, so the original text is forwarded after the
/// duplicate-key check; only notifications and replies that feed a host-side observer are parsed.
nonisolated final class AcpmuxRequestIds: Sendable {
    /// Notifications a host observer reads (``toPage(_:)``); never shed (``AcpmuxPaneShedding``).
    static let observedNotificationMethods = [
        "_acpmux/prompt_accepted", "_acpmux/event", "_acpmux/permission_pending",
    ]
    static let eventObserverMarkers = [
        "\"permission_request\"", "\"permission_reissued\"", "\"permission_decision\"",
    ]

    private nonisolated struct Entry {
        var pageID: String
        var method: String
        /// The chat a reply in place named (``AgentPaneAgentReply``).
        var subject: String?
        /// Put on the daemon's socket (``written(_:)``): a frame still held by a host check (a
        /// path check, a confirmation sheet) is not one the daemon could have read.
        var written = false
    }

    private nonisolated struct State {
        var next = 1
        var entries: [Int: Entry] = [:]
        var inFlight: Set<String> = []
        /// Told when the daemon answers a relay id (``whenAnswered(_:_:)``).
        var answered: [Int: @Sendable (Bool) -> Void] = [:]
        /// Each `_acpmux/request_state` question on the wire: the relay ids written before it,
        /// which the daemon read before the question (``snapshotWritten(for:)``).
        var stateQueries: [Int: [Int]] = [:]
    }

    /// The page asks which of its requests the daemon still runs (acpmux `server/in_flight.rs`
    /// `states`; webviews `direct.ts` `checkRequests`). The daemon answers in relay ids; the page
    /// gets its own ids, and `relayed`: its requests this relay wrote to the daemon before the
    /// question, the only ones the answer speaks for. A request the host answers itself
    /// (`_acpmux/status`) or still holds is never in it, so it is never judged lost.
    static let requestStateMethod = "_acpmux/request_state"

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
            state.stateQueries[id] = nil
        }
    }

    /// Request `id` is on the daemon's socket, after every frame written before it.
    func written(_ id: Int) {
        state.withLock { $0.entries[id]?.written = true }
    }

    /// Just before `_acpmux/request_state` question `id` is written: the requests written before
    /// it, which the daemon reads before the question. One written later is left out (no verdict).
    func snapshotWritten(for id: Int) {
        state.withLock { state in
            guard state.entries[id]?.method == Self.requestStateMethod else { return }
            state.stateQueries[id] = state.entries.compactMap { relayID, entry in
                entry.written && entry.method != Self.requestStateMethod ? relayID : nil
            }
        }
    }

    /// The daemon's answer to question `relayID` in the page's ids: `running` and `answered` as
    /// the daemon said, and `relayed` (``requestStateMethod``). A relay id whose reply already went
    /// to the page is left out of all three: the page has its answer. An error goes as it came.
    private func requestState(_ object: [String: Any], relayID: Int) -> [String: Any] {
        var object = object
        let snapshot = state.withLock { $0.stateQueries.removeValue(forKey: relayID) } ?? []
        guard let result = object["result"] as? [String: Any] else { return object }
        let pages = state.withLock { state -> [Int: String] in
            state.entries.compactMapValues { $0.method == Self.requestStateMethod ? nil : $0.pageID }
        }
        func pageIDs(_ value: Any?) -> [Any] {
            ((value as? [Any]) ?? []).compactMap { raw -> Any? in
                guard let relay = (raw as? NSNumber)?.intValue ?? (raw as? Int), let page = pages[relay] else { return nil }
                return Self.value(page)
            }
        }
        object["result"] = [
            "running": pageIDs(result["running"]),
            "answered": pageIDs(result["answered"]),
            "relayed": pageIDs(snapshot),
        ]
        return object
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
        /// A reply no host observer reads, as the daemon's own text with the page's id put in place
        /// of the relay's: no Foundation parse, no re-encode (``toPage(_:)``).
        case reply(String, replyTo: String)
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
        /// The escape check's parse of a frame without a method (a reply), kept for the reply path.
        var replyObject: [String: Any]?
        // JSON method names are normally plain ASCII. If an escaped method value or top-level key
        // appears, use Foundation once to decode that rare spelling before deciding whether host
        // observers need the object; plain stream notifications and replies whose escapes are all
        // inside values (a transcript's text) never take this path.
        if method?.contains("\\") == true || (!methodScan.found && methodScan.escapedKey) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                if let decoded = object["method"] as? String {
                    method = decoded
                    notificationObject = object
                } else {
                    replyObject = object
                }
            }
        }
        if let method, Self.observedNotificationMethods.contains(method) {
            // Most `_acpmux/event` frames are transcript chunks. The host only reads permission
            // records from that stream; pacing for turn boundaries uses the raw text path below.
            if method == "_acpmux/event" &&
                !text.utf8ContainsAny(Self.eventObserverMarkers) {
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
            // Opaque: its method still goes along, for the page-wait check (``AcpmuxPaneSocket/pageWaits(on:method:)``).
            return .page(text, object: nil, replyTo: method)
        }
        // A reply. Its relay id is read from the text when the scan found it as a plain integer
        // under an unescaped key, so a history page no observer reads is never parsed: it goes on
        // as the daemon wrote it, with the page's id spliced in (the duplicate-key check above
        // already read it as one JSON text, as for a notification). Anything else is parsed.
        if replyObject == nil, let span = methodScan.id, let relayID = Self.integer(text, span) {
            state.withLock { $0.answered.removeValue(forKey: relayID) }?(!methodScan.error && methodScan.result)
            guard let entry = take(relayID), let id = Self.value(entry.pageID) else { return .drop }
            if Self.passesThrough(entry.method, text) {
                return .reply(Self.splice(text, span, entry.pageID), replyTo: entry.method)
            }
            guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .drop }
            object["id"] = id
            if entry.method == Self.requestStateMethod { return reply(requestState(object, relayID: relayID), entry: entry, text: nil) }
            return reply(object, entry: entry, text: AcpmuxPaneMethods.replyShapes[entry.method] == nil ? Self.splice(text, span, entry.pageID) : nil)
        }
        guard var object = replyObject ?? (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .drop }
        guard let relayID = object["id"].flatMap(AcpmuxPaneMethods.rawID).flatMap({ Int($0) }) else { return .drop }
        state.withLock { $0.answered.removeValue(forKey: relayID) }?(object["error"] == nil && object["result"] != nil)
        guard let entry = take(relayID), let id = Self.value(entry.pageID) else { return .drop }
        object["id"] = id
        if entry.method == Self.requestStateMethod { return reply(requestState(object, relayID: relayID), entry: entry, text: nil) }
        return reply(object, entry: entry, text: nil)
    }

    /// The request a reply answers, removed from the ones in flight.
    private func take(_ relayID: Int) -> Entry? {
        state.withLock { state -> Entry? in
            guard let entry = state.entries.removeValue(forKey: relayID) else { return nil }
            state.inFlight.remove(entry.pageID)
            return entry
        }
    }

    /// A parsed reply (its id already the page's) to the page or the host; `text`, when given, is
    /// the daemon's text with the page's id, sent in place of a fresh serialization.
    private func reply(_ object: [String: Any], entry: Entry, text: String?) -> Inbound {
        // The page id is free again from here, while the host still sends the reply: the page
        // never reuses an id (direct.ts counts them up), so its answer cannot go to another request.
        if entry.method == AgentPaneAgentReply.method {
            return .complete(object: object, pageID: entry.pageID, subject: entry.subject)
        }
        if let shape = AcpmuxPaneMethods.replyShapes[entry.method] {
            return .page(AcpmuxPaneMethods.filteredReply(object, shape: shape, pageID: entry.pageID), object: object, replyTo: entry.method)
        }
        guard let fresh = text ?? Self.encode(object) else { return .drop }
        return .page(fresh, object: object, replyTo: entry.method)
    }

    /// Replies whose records a host observer reads only when they hold a permission record
    /// (``AcpmuxDecisionContexts``, ``AgentPaneUserGestures``: the `permission_request`,
    /// `permission_reissued` and `permission_decision` records of a history page). Every other
    /// reply is parsed for its observers (an attach's session folder and open prompts, a start).
    static let passThroughReplies: Set<String> = ["_acpmux/events"]

    /// Whether the reply to `method` reaches the page without a host parse.
    static func passesThrough(_ method: String, _ text: String) -> Bool {
        passThroughReplies.contains(method) && !text.utf8ContainsAny(eventObserverMarkers)
    }

    /// The integer at `span` of `text` (a relay id is one the relay counted up).
    private static func integer(_ text: String, _ span: Range<Int>) -> Int? {
        var text = text
        return text.withUTF8 { bytes in
            guard span.upperBound <= bytes.count, span.count <= 18 else { return nil }
            var value = 0
            for byte in bytes[span] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
    }

    /// `text` with the bytes at `span` (the relay id) replaced by `pageID` (a JSON value's text).
    static func splice(_ text: String, _ span: Range<Int>, _ pageID: String) -> String {
        var text = text
        return text.withUTF8 { bytes in
            var out = [UInt8]()
            out.reserveCapacity(bytes.count + pageID.utf8.count)
            out.append(contentsOf: bytes[..<span.lowerBound])
            out.append(contentsOf: pageID.utf8)
            out.append(contentsOf: bytes[span.upperBound...])
            return String(decoding: out, as: UTF8.self)
        }
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
        /// The byte range of a top-level `"id"` whose value is a plain non-negative integer; nil
        /// when there is none, or when any top-level key holds an escape (the parse decides then).
        var id: Range<Int>?
        /// Whether a top-level `result` or `error` key was seen (read only when no method was found).
        var result = false
        var error = false
        /// Whether a top-level key holds an escape (read only when no method was found).
        var escapedKey = false
    }

    private static func topLevelMethod(_ text: String) -> MethodScan {
        var text = text
        return text.withUTF8 { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return MethodScan(found: false, value: nil) }
            var depth = 0
            var i = 0
            var reply = MethodScan(found: false, value: nil)
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
                    if depth == 1 {
                        // A top-level key: the reply's id, result and error.
                        var next = i + 1
                        while next < bytes.count, base[next] == 0x20 || base[next] == 0x09 || base[next] == 0x0A || base[next] == 0x0D { next += 1 }
                        if next < bytes.count, base[next] == 0x3A {
                            let key = UnsafeBufferPointer(rebasing: bytes[start..<min(i, bytes.count)])
                            if key.contains(0x5C) { reply.escapedKey = true }
                            if key.elementsEqual("result".utf8) { reply.result = true }
                            if key.elementsEqual("error".utf8) { reply.error = true }
                            if key.elementsEqual("id".utf8) {
                                var value = next + 1
                                while value < bytes.count, base[value] == 0x20 || base[value] == 0x09 || base[value] == 0x0A || base[value] == 0x0D { value += 1 }
                                var end = value
                                while end < bytes.count, (0x30...0x39).contains(base[end]) { end += 1 }
                                // A plain integer: digits, then a separator (no fraction, exponent or sign).
                                let plain = end > value && (end == bytes.count || [0x2C, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(base[end]))
                                reply.id = plain ? value..<end : nil
                            }
                        }
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
            if reply.escapedKey { reply.id = nil }
            return reply
        }
    }
}
