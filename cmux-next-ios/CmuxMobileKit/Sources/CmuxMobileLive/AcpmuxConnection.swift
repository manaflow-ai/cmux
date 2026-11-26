import CmuxMobileAgentChat
import enum CmuxMobileModel.UserFacingError
import CmuxMobileTransport
import Foundation
import OSLog

private let rpcLog = Logger(subsystem: "dev.cmux.mobile", category: "acpmux-rpc")

/// JSON-RPC 2.0 over a link's `acpmux` channel: one link data frame carries
/// one WebSocket text message (PROTOCOL.md "Link"). Requests resolve by id;
/// everything else arrives on `notifications`.
public actor AcpmuxConnection {
    public struct RPCError: Error, Equatable, Sendable {
        public var code: Int
        public var message: String
        /// `error.data.reason` (for example `permission.person_required`, `trust.pending`).
        public var reason: String?
        /// `error.data.retryAfterMs`: when acpmux paces a request (`list.paced`), how long to wait.
        public var retryAfterMs: Int? = nil
        /// `error.data.origin` and `error.data.code` (a string): Rust tells a "not now" from a
        /// real refusal by them and `reason`; Swift only carries them.
        public var origin: String? = nil
        public var dataCode: String? = nil
    }

    public struct Notification: Sendable {
        public var method: String
        public var params: JSONValue
    }

    private let channel: any LinkChannel
    /// The link's last progress (its Mac's ``MacSession/progress``, or this channel's own): every
    /// frame heard and every completed write contributes to the Mac's link status.
    nonisolated let progress: LinkProgress
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var sends: [Int: Task<Void, Never>] = [:]
    private var ended: (any Error)?
    var isClosed: Bool { ended != nil }
    public nonisolated let notifications: AsyncStream<Notification>
    private let continuation: AsyncStream<Notification>.Continuation

    /// The `acpmux` channel's open args: large replies (the chat list) come compressed from a
    /// Mac that can (`DeflatedMessage`, CMUX-563); an older Mac ignores them.
    public static let channelArgs = ["compression": "deflate"]

    /// `held`: a channel opened before this phone checked the Mac (``AcpmuxHub/bind(_:requestTimeout:until:)``).
    /// Until ``admit()``, nothing reaches `notifications`: at most ``heldNotificationLimit``
    /// notifications of at most ``heldByteLimit`` bytes in all wait here, a compressed message
    /// inflates to at most what is left of those bytes, and a Mac that sends more is cut off
    /// (the channel closes), so a peer that never passes the check cannot fill the phone's memory.
    /// The answers to this phone's own requests are kept whole, as on any connection: one each,
    /// at most ``MessageJoiner/maxMessage``, so an older Mac's whole chat list still arrives.
    public init(channel: any LinkChannel, held: Bool = false, progress: LinkProgress = LinkProgress()) {
        self.channel = channel
        self.progress = progress
        (notifications, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        if held { self.held = [] }
    }

    /// Notifications kept before ``admit()``: a watch reports changes as soon as it answers,
    /// which can be before this phone's own check of the Mac finished.
    static let heldNotificationLimit = 256
    /// Bytes of the notifications kept before ``admit()``, and the most a compressed message
    /// may inflate to then (a paged first page, 100 rows, is far less).
    static let heldByteLimit = 8 << 20
    /// Non-nil until ``admit()``.
    private var held: [Notification]?
    private var heldBytes = 0
    /// Bytes counted against ``heldByteLimit`` so far (tests).
    var heldByteCount: Int { heldBytes }
    /// Why the Mac is cut off before ``admit()`` (nil: within the limits).
    private var cutOff: String?

    /// This phone checked the Mac: what waited goes out on `notifications`, and from now on
    /// everything does.
    public func admit() {
        guard let waiting = held else { return }
        held = nil
        heldBytes = 0
        for notification in waiting { continuation.yield(notification) }
    }

    public func start() {
        guard readTask == nil, ended == nil else { return }
        readTask = Task { await self.readLoop() }
    }

    /// Prompts resolve when the turn ends, which can include a person answering an
    /// approval. Other requests are short reads or mutations; both have finite bounds.
    static func replyTimeout(for method: String) -> Duration {
        method == "session/prompt" ? .seconds(24 * 60 * 60) : .seconds(30)
    }

    public func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await request(method, params, timeout: Self.replyTimeout(for: method))
    }

    /// A late reply is ignored; cancellation and expiry release the request and
    /// cancel its write without closing unrelated requests on the same channel.
    public func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try Task.checkCancellation()
        if let ended { throw ended }
        start()
        let id = nextID
        nextID += 1
        let isWrite = !AcpmuxHub.steadyMethods.contains(method)
        if isWrite { writes.insert(id) }
        defer { if isWrite { writes.remove(id) } }
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                                          "params": Self.traced(params)])
        let data = try JSONEncoder().encode(message)
        rpcLog.debug("-> \(id) \(method, privacy: .public) \(data.count) bytes")
        let traceStart = PhoneTrace.traceID == nil ? nil : PhoneTrace.Recorder.now()
        defer { if let traceStart { PhoneTrace.roundTrip(method, start: traceStart) } }
        return try await LinkDeadline.run(
            timeout: timeout,
            timeoutError: LinkError(code: "timeout", message: "no reply to \(method)"),
            operation: { try await self.sendAndWait(id: id, data: data) },
            onCancel: { await self.fail(id, CancellationError()) }
        )
    }

    private func sendAndWait(id: Int, data: Data) async throws -> JSONValue {
        try Task.checkCancellation()
        if let ended { throw ended }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            sends[id] = Task {
                do {
                    try Task.checkCancellation()
                    try await channel.send(data)
                    sends[id] = nil
                } catch { fail(id, error) }
            }
        }
    }

    /// The whole `sessions` of a list call with no `limit` (`_acpmux/watch`, `_acpmux/sessions`).
    /// acpmux answers a list past its largest reply with the first rows and a string `nextCursor`;
    /// the rest comes from `_acpmux/sessions` with the same params (no `enabled`) and that cursor,
    /// until a page has none (acpmux `Client::whole_list`). A list that fits is one reply with no
    /// cursor, so an older daemon is read as before. A cursor that is not a string, a cursor sent
    /// twice, or a page with no `sessions` throws: a caller reads a missing session as a gone one,
    /// so a list cut short is never handed back. Each page is bounded by `timeout`.
    public func wholeList(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> [JSONValue] {
        var reply = try await request(method, .object(params), timeout: timeout)
        var rows = try Self.pageRows(reply)
        var rest = params
        rest["enabled"] = nil
        var seen: Set<String> = []
        while let cursor = try Self.nextCursor(reply) {
            guard seen.insert(cursor).inserted else {
                throw RPCError(code: 0, message: "acpmux sent a session list cursor again", reason: "sessions.cursor_repeated")
            }
            rest["cursor"] = .string(cursor)
            reply = try await request("_acpmux/sessions", .object(rest), timeout: timeout)
            rows += try Self.pageRows(reply)
        }
        return rows
    }

    /// A list page's `sessions`; a page without the array is not a page of the list.
    nonisolated static func pageRows(_ reply: JSONValue) throws -> [JSONValue] {
        guard let rows = reply["sessions"]?.arrayValue else {
            throw RPCError(code: 0, message: "acpmux sent a session list page with no sessions", reason: "sessions.bad_page")
        }
        return rows
    }

    /// A list page's `nextCursor`: a string continues (an empty page included), null or absent
    /// ends the list, anything else throws.
    nonisolated static func nextCursor(_ reply: JSONValue) throws -> String? {
        switch reply["nextCursor"] {
        case nil, .null?: return nil
        case let .string(cursor)?: return cursor
        case let other?:
            throw RPCError(code: 0, message: "acpmux sent the session list cursor \(other)", reason: "sessions.bad_cursor")
        }
    }

    /// Writes a request and returns its id once the channel took it; ``reply(to:)`` waits for
    /// its answer. Requests a caller submits one after another reach the Mac in that order
    /// (``request(_:_:)`` writes from a task of its own), and the caller need not wait for an
    /// answer before the next: a `session/prompt` is answered only when its turn ends.
    /// An observed write continues while its own chunks enter the transport. For a channel
    /// without a per-write counter, the deadline scales with the encoded payload.
    public func submit(_ method: String, _ params: JSONValue, timeout: Duration? = nil,
                       base: Duration = AcpmuxConnection.writeBase) async throws -> Int {
        try Task.checkCancellation()
        if let ended { throw ended }
        start()
        let id = nextID
        nextID += 1
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                                          "params": Self.traced(params)])
        let data = try JSONEncoder().encode(message)
        rpcLog.debug("-> \(id) \(method, privacy: .public) \(data.count) bytes (submitted)")
        // The write, not the answer (a prompt's comes when its turn ends).
        let traceStart = PhoneTrace.traceID == nil ? nil : PhoneTrace.Recorder.now()
        defer { if let traceStart { PhoneTrace.roundTrip(method, start: traceStart, args: ["write": true]) } }
        submitted.insert(id)
        if !AcpmuxHub.steadyMethods.contains(method) {
            writes.insert(id)
            // Bounded by this write's own deadline below, so a recovery it holds off is too.
            sending.insert(id)
        }
        defer { sending.remove(id) }
        let write = channel.observedWrite(data)
        let window = timeout ?? (write.takeProgress == nil ? Self.writeBound(bytes: data.count, base: base) : base)
        do {
            try await LinkDeadline.run(
                timeout: window,
                timeoutError: LinkError(code: "timeout", message: "write of \(method) made no progress"),
                extend: { write.takeProgress?() == true ? window : nil },
                operation: write.send,
                onCancel: { write.cancel() }
            )
        } catch {
            release(id)
            throw error
        }
        progress.progressed()
        return id
    }

    /// `params` with the current user action's trace id in `_meta.traceId` (``PhoneTrace``), which
    /// acpmux's tracer keys its spans by (`perf_trace.rs` `trace_id_of`); unchanged outside an
    /// action or when `params` is not an object. Other `_meta` keys stay.
    nonisolated static func traced(_ params: JSONValue) -> JSONValue {
        guard let traceID = PhoneTrace.traceID, case .object(var fields) = params else { return params }
        var meta: [String: JSONValue] = [:]
        if case .object(let existing)? = fields["_meta"] { meta = existing }
        meta["traceId"] = .string(traceID)
        fields["_meta"] = .object(meta)
        return .object(fields)
    }

    /// The fixed part of a write's bound: a link that takes no data for this long is down.
    public static let writeBase: Duration = .seconds(30)
    /// The slowest link a write is still expected to finish on, in bytes a second: a prompt with
    /// an inline image or PDF (several MB of base64) on a slow cellular link.
    static let writeFloorRate = 16 * 1024

    /// How long a write of `bytes` may take: `base`, plus its bytes at ``writeFloorRate``. A fixed
    /// bound cut off a large prompt that was still going out on a slow link, and the prompt came
    /// back as "unreachable" though the Mac was there. Channels without per-write observations
    /// use this bound for a complete write.
    public static func writeBound(bytes: Int, base: Duration = writeBase) -> Duration {
        base + .milliseconds(Int64(max(0, bytes)) * 1000 / Int64(writeFloorRate))
    }

    /// A submitted request whose write failed, timed out or was cancelled: nothing waits for it.
    private func release(_ id: Int) {
        sending.remove(id)
        submitted.remove(id)
        writes.remove(id)
        answered[id] = nil
    }

    /// The answer to a ``submit(_:_:)``ed request (one that came before this call was kept).
    public func reply(to id: Int) async throws -> JSONValue {
        if let early = answered.removeValue(forKey: id) {
            submitted.remove(id)
            return try early.get()
        }
        guard submitted.contains(id) else {
            throw ended ?? LinkError(code: "closed", message: "acpmux channel closed")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    /// Submitted requests not yet answered to their ``reply(to:)``, and answers that came
    /// before it was called.
    private var submitted: Set<Int> = []
    /// Requests and submits other than idempotent reads (``AcpmuxHub/steadyMethods``) the Mac has
    /// not answered yet. An answer, a release or the channel's end takes each out (an answer kept
    /// for a later ``reply(to:)`` is no longer in flight).
    private var writes: Set<Int> = []

    /// A prompt or mutation is still waiting for the Mac on this channel: a slow answer here is
    /// work, not a stall, and closing the channel would lose it.
    var hasWritesInFlight: Bool { !writes.isEmpty }
    /// Submitted writes (``submit(_:_:timeout:base:)``, not idempotent reads) whose bytes are still
    /// going out on the channel: the channel has not taken them whole yet.
    private var sending: Set<Int> = []
    /// A write is still going out: a read behind it on this channel is slow, not stalled (the Mac
    /// cannot answer what has not reached it), and the write is bounded by its own deadline.
    var isSending: Bool { !sending.isEmpty }
    private var answered: [Int: Result<JSONValue, any Error>] = [:]

    /// A JSON-RPC notification (no id, no reply), e.g. `session/cancel`.
    public func notify(_ method: String, _ params: JSONValue) async throws {
        if let ended { throw ended }
        start()
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        try await channel.send(try JSONEncoder().encode(message))
    }

    public func close() async {
        readTask?.cancel()
        finish(LinkError(code: "closed", message: "acpmux channel closed"))
        await channel.close(code: "eof", reason: "client closed")
    }

    private func fail(_ id: Int, _ error: any Error) {
        sends.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func readLoop() async {
        do {
            while let message = try await channel.receive() {
                route(message)
                if held != nil, let cutOff {
                    rpcLog.error("acpmux: \(cutOff, privacy: .public) before this phone checked the Mac; closing")
                    finish(LinkError(code: "refused", message: "The Mac sent too much before pairing finished"))
                    await channel.close(code: "eof", reason: "too much before pairing")
                    return
                }
            }
            finish(LinkError(code: "closed", message: "acpmux channel closed"))
        } catch {
            finish(error)
        }
    }

    /// One link data frame. The link splits a message above 256 KiB into
    /// full-size frames (PROTOCOL.md "Link"), so frames join until they parse
    /// as one JSON value: a transcript record carrying an image arrives whole.
    func route(_ data: Data) {
        // Bytes heard from the Mac: the link is moving.
        progress.progressed()
        guard cutOff == nil else { return }
        var joiner = frames
        // Before the check every message, plain or compressed, grows to at most what is left of
        // the budget while it arrives, unless its first bytes answer one of this phone's own
        // requests still waiting: that one may be as long as any message, once per request.
        joiner.budget = held == nil ? MessageJoiner.maxMessage : max(0, Self.heldByteLimit - heldBytes)
        joiner.replyIDs = held == nil ? [] : submitted.subtracting(claimedReplies)
        let message = joiner.push(data)
        let refused = joiner.takeRefused()
        if let id = joiner.takeClaimed() { claimedReplies.insert(id) }
        frames = joiner
        if held != nil, let refused {
            cutOff = "a message of \(refused) bytes"
            return
        }
        guard let value = message else {
            rpcLog.debug("frame of \(data.count) bytes is not a whole JSON message yet")
            return
        }
        dispatch(value, bytes: joiner.lastBytes)
    }

    private var frames = MessageJoiner()
    /// Requests whose answer already took its allowance before the check (one message each).
    private var claimedReplies: Set<Int> = []

    /// `bytes`: the message's length as read (inflated, for a compressed one).
    private func dispatch(_ value: JSONValue, bytes: Int) {
        if let id = value["id"]?.numberValue, value["method"] == nil {
            let outcome: Result<JSONValue, any Error>
            if let error = value["error"] {
                outcome = .failure(RPCError(
                    code: Int(error["code"]?.numberValue ?? 0),
                    message: error["message"]?.stringValue ?? "error",
                    reason: error["data"]?["reason"]?.stringValue,
                    retryAfterMs: error["data"]?["retryAfterMs"]?.numberValue.map { Int(min(max($0, 0), 60_000)) },
                    origin: error["data"]?["origin"]?.stringValue,
                    dataCode: error["data"]?["code"]?.stringValue
                ))
            } else {
                outcome = .success(value["result"] ?? .null)
            }
            writes.remove(Int(id))
            guard let continuation = pending.removeValue(forKey: Int(id)) else {
                // A submitted request answered before its ``reply(to:)``: keep it for the caller.
                if submitted.contains(Int(id)) {
                    answered[Int(id)] = outcome
                } else {
                    rpcLog.debug("<- \(Int(id)) with no request waiting")
                }
                return
            }
            submitted.remove(Int(id))
            sends.removeValue(forKey: Int(id))?.cancel()
            rpcLog.debug("<- \(Int(id)) \(value["error"] == nil ? "result" : "error", privacy: .public)")
            continuation.resume(with: outcome)
        } else if let method = value["method"]?.stringValue {
            let notification = Notification(method: method, params: value["params"] ?? .null)
            if held != nil {
                // Past either limit nothing more is kept, and the read loop closes the channel.
                heldBytes += bytes
                if (held?.count ?? 0) >= Self.heldNotificationLimit {
                    cutOff = "more than \(Self.heldNotificationLimit) notifications"
                } else if heldBytes > Self.heldByteLimit {
                    cutOff = "more than \(Self.heldByteLimit) bytes of notifications"
                } else {
                    held?.append(notification)
                }
                return
            }
            continuation.yield(notification)
        }
    }

    /// Joins the data frames of one JSON message. The link writes a message in
    /// chunks of at most `chunk` bytes (cmux-mobile-link `DATA_CHUNK`, 16 KiB; older Macs
    /// 256 KiB), so a frame of that size or more may continue; a shorter frame ends
    /// the message. A short frame that does not complete what is pending, but is a
    /// whole message itself, starts over (an earlier chunk was lost).
    struct MessageJoiner {
        /// The link's smallest full chunk: a frame this size or larger may continue.
        static let chunk = 16 * 1024
        /// The largest frame an older Mac's link sends (kept for the tests' split).
        static let fullFrame = 256 * 1024
        static let maxMessage = 64 << 20
        private var pending = Data()
        /// The longest a message may grow to while its frames arrive (its text, inflated for a
        /// compressed one): ``maxMessage``, or before the pairing check what is left of
        /// ``AcpmuxConnection/heldByteLimit``.
        var budget = Self.maxMessage
        /// Before the pairing check, this phone's own requests still waiting: a message whose
        /// first bytes give one of these ids may be as long as ``maxMessage`` (``takeClaimed()``).
        var replyIDs: Set<Int> = []
        /// The limit of the message being joined; nil until its first bytes are in.
        private var limit: Int?
        /// The length of the last message returned (its text, inflated for a compressed one).
        private(set) var lastBytes = 0
        /// The length of a message refused since the last ``takeRefused()``: longer than its
        /// limit (a compressed one by its header, before it is inflated).
        private var refused: Int?
        /// The request id a message took the answer's allowance for, since the last ``takeClaimed()``.
        private var claimed: Int?

        mutating func takeRefused() -> Int? {
            defer { refused = nil }
            return refused
        }

        mutating func takeClaimed() -> Int? {
            defer { claimed = nil }
            return claimed
        }

        /// The message once complete, else nil (waiting, or a frame that was dropped).
        mutating func push(_ frame: Data) -> JSONValue? {
            // A compressed message (`DeflatedMessage`): its header says where it ends.
            if (pending.first ?? frame.first) == DeflatedMessage.marker {
                return pushDeflated(frame)
            }
            if pending.isEmpty { start(Self.leadingID(frame)) }
            pending.append(frame)
            // A whole JSON message ends with `}` or `]` (acpmux sends objects): parse only
            // then, so a large message is not parsed again on each of its chunks.
            if Self.mayEnd(pending), let value = Self.decode(pending) {
                lastBytes = pending.count
                reset()
                return value
            }
            let limit = limit ?? budget
            if pending.count > limit {
                refused = pending.count
                reset()
                return nil
            }
            if frame.count >= Self.chunk {
                return nil
            }
            let stale = pending.count > frame.count
            reset()
            lastBytes = frame.count
            return stale && Self.mayEnd(frame) && frame.count <= budget ? Self.decode(frame) : nil
        }

        /// A message whose first bytes gave `id` starts: an answer to one of ``replyIDs`` may be
        /// as long as any message, everything else as long as ``budget``.
        private mutating func start(_ id: Int?) {
            if let id, replyIDs.contains(id) {
                limit = Self.maxMessage
                claimed = id
            } else {
                limit = budget
            }
        }

        private mutating func reset() {
            pending = Data()
            limit = nil
        }

        private mutating func pushDeflated(_ frame: Data) -> JSONValue? {
            pending.append(frame)
            if limit == nil, let header = DeflatedMessage(header: pending) {
                // The id comes from the first bytes of the text, inflated from what is in so far.
                if let text = DeflatedMessage.textPrefix(pending.prefix(DeflatedMessage.headerBytes + Self.peekBytes), count: 64) {
                    start(Self.leadingID(text))
                } else if pending.count >= DeflatedMessage.headerBytes + min(header.deflateBytes, Self.peekBytes) {
                    // The first bytes of a reply inflate from far fewer: this one is not a reply.
                    start(nil)
                }
            }
            if pending.count > max(limit ?? budget, Self.chunk) + DeflatedMessage.headerBytes {
                // Never more compressed bytes than the text they inflate to may hold.
                refused = pending.count
                reset()
                return nil
            }
            guard let limit else { return nil }
            if let header = DeflatedMessage(header: pending), header.textBytes > limit {
                refused = header.textBytes
                reset()
                return nil
            }
            switch DeflatedMessage.state(pending, limit: limit) {
            case .waiting:
                return nil
            case .whole(let text, let used):
                lastBytes = text.count
                // A frame never holds two messages, so bytes past the envelope that came with an
                // earlier frame mean one of its frames was lost: this frame starts the next.
                let lost = pending.count > used && pending.count > frame.count
                reset()
                // More bytes than the envelope holds: a frame of it was lost and this frame
                // starts the next message. Read that frame alone.
                return lost ? push(frame) : Self.decode(text)
            case .bad:
                let lost = pending.count > frame.count
                reset()
                return lost ? push(frame) : nil
            }
        }

        /// The id at the start of an answer's text: `{"id":N` or `{"jsonrpc":"2.0","id":N`, the
        /// two orders acpmux writes (serde_json sorts keys unless `preserve_order` is on); nil for
        /// anything else, a notification included.
        /// How many compressed bytes are inflated to find a message's id.
        static let peekBytes = 4096

        static func leadingID(_ text: Data) -> Int? {
            let bytes = [UInt8](text.prefix(64))
            var at = 0
            func skipSpace() {
                while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0a || bytes[at] == 0x0d || bytes[at] == 0x09 { at += 1 }
            }
            func take(_ literal: String) -> Bool {
                skipSpace()
                let want = Array(literal.utf8)
                guard at + want.count <= bytes.count, Array(bytes[at..<(at + want.count)]) == want else { return false }
                at += want.count
                return true
            }
            guard take("{") else { return nil }
            if take("\"jsonrpc\""), !(take(":") && take("\"2.0\"") && take(",")) { return nil }
            guard take("\"id\""), take(":") else { return nil }
            skipSpace()
            var id = 0
            var digits = 0
            while at < bytes.count, bytes[at] >= 0x30, bytes[at] <= 0x39, digits < 9 {
                id = id * 10 + Int(bytes[at] - 0x30)
                at += 1
                digits += 1
            }
            return digits > 0 ? id : nil
        }

        private static func mayEnd(_ data: Data) -> Bool {
            guard let last = data.last(where: { !($0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09) }) else { return false }
            return last == UInt8(ascii: "}") || last == UInt8(ascii: "]")
        }

        private static func decode(_ data: Data) -> JSONValue? {
            // `JSONSerialization` parses without a thrown error per value (`JSONValue`'s own
            // `Decodable` tries each JSON type in turn); `JSONDecoder` reads what it refuses.
            JSONValue(jsonData: data) ?? (try? JSONDecoder().decode(JSONValue.self, from: data))
        }
    }

    private func finish(_ error: any Error) {
        guard ended == nil else { return }
        ended = error
        // What waited for the check is dropped, never delivered.
        if held != nil { held = [] }
        for task in sends.values { task.cancel() }
        sends.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        // A submitted request whose `reply(to:)` is still to come fails there.
        for id in submitted where pending[id] == nil && answered[id] == nil { answered[id] = .failure(error) }
        submitted.subtract(pending.keys)
        writes.removeAll()
        sending.removeAll()
        pending.removeAll()
        continuation.finish()
    }
}

/// What a person reads for a refused acpmux call: the reason's copy, the Mac's own
/// sentence, or a plain fallback. Never the JSON-RPC code or the type. No "again in a
/// moment": a paced list is asked again on its own (`AcpmuxHub+SessionPages`, AutoRetry).
extension AcpmuxConnection.RPCError: LocalizedError {
    public var errorDescription: String? {
        switch reason {
        case "permission.person_required":
            return "Allow this iPhone in the Mac's Settings → Mobile, or approve on the Mac."
        case "trust.pending", "trust.untrusted": return "Trust this folder on your Mac first."
        case "remote.lasting_grant_refused": return "From an iPhone you can allow once or deny. Allow for this chat on the Mac."
        case "remote.full_access_required": return "Full access is off for this iPhone. Turn it on in Settings > Devices on the Mac."
        case "list.paced": return "Your Mac is busy right now."
        default: break
        }
        if message.hasPrefix("no pending permission") { return "Already answered on your Mac." }
        // An agent's raw JSON error (a model the account lacks) reads as a sentence.
        if message.contains("{"), message.contains("}") { return TurnFailureCopy.plain(message) }
        if UserFacingError.isProse(message) { return message.trimmingCharacters(in: .whitespacesAndNewlines) }
        if retryAfterMs != nil { return "Your Mac is busy right now." }
        return "Your Mac couldn't do that."
    }
}
