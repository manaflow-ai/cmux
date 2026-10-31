import CmuxMobileAgentChat
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
    }

    public struct Notification: Sendable {
        public var method: String
        public var params: JSONValue
    }

    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var sends: [Int: Task<Void, Never>] = [:]
    private var ended: (any Error)?
    var isClosed: Bool { ended != nil }
    public nonisolated let notifications: AsyncStream<Notification>
    private let continuation: AsyncStream<Notification>.Continuation

    public init(channel: any LinkChannel) {
        self.channel = channel
        (notifications, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
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
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        let data = try JSONEncoder().encode(message)
        rpcLog.debug("-> \(id) \(method, privacy: .public) \(data.count) bytes")
        return try await LinkDeadline.run(
            timeout: timeout,
            timeoutError: LinkError(code: "timeout", message: "The Mac didn't answer (\(method))"),
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
        var joiner = frames
        let message = joiner.push(data)
        frames = joiner
        guard let value = message else {
            rpcLog.debug("frame of \(data.count) bytes is not a whole JSON message yet")
            return
        }
        dispatch(value)
    }

    private var frames = MessageJoiner()

    private func dispatch(_ value: JSONValue) {
        if let id = value["id"]?.numberValue, value["method"] == nil {
            guard let continuation = pending.removeValue(forKey: Int(id)) else {
                rpcLog.debug("<- \(Int(id)) with no request waiting")
                return
            }
            sends.removeValue(forKey: Int(id))?.cancel()
            rpcLog.debug("<- \(Int(id)) \(value["error"] == nil ? "result" : "error", privacy: .public)")
            if let error = value["error"] {
                continuation.resume(throwing: RPCError(
                    code: Int(error["code"]?.numberValue ?? 0),
                    message: error["message"]?.stringValue ?? "error",
                    reason: error["data"]?["reason"]?.stringValue
                ))
            } else {
                continuation.resume(returning: value["result"] ?? .null)
            }
        } else if let method = value["method"]?.stringValue {
            continuation.yield(Notification(method: method, params: value["params"] ?? .null))
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

        /// The message once complete, else nil (waiting, or a frame that was dropped).
        mutating func push(_ frame: Data) -> JSONValue? {
            pending.append(frame)
            // A whole JSON message ends with `}` or `]` (acpmux sends objects): parse only
            // then, so a large message is not parsed again on each of its chunks.
            if Self.mayEnd(pending), let value = Self.decode(pending) {
                pending = Data()
                return value
            }
            if frame.count >= Self.chunk, pending.count <= Self.maxMessage {
                return nil
            }
            let stale = pending.count > frame.count
            pending = Data()
            return stale && Self.mayEnd(frame) ? Self.decode(frame) : nil
        }

        private static func mayEnd(_ data: Data) -> Bool {
            guard let last = data.last(where: { !($0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09) }) else { return false }
            return last == UInt8(ascii: "}") || last == UInt8(ascii: "]")
        }

        private static func decode(_ data: Data) -> JSONValue? {
            try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    private func finish(_ error: any Error) {
        guard ended == nil else { return }
        ended = error
        for task in sends.values { task.cancel() }
        sends.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        continuation.finish()
    }
}
