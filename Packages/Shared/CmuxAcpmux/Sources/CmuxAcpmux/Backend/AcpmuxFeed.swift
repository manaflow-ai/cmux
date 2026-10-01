public import CmuxConversation

/// One acpmux session's event feed: attaches, folds gaps by replaying from
/// its cursor, pages backwards, and re-attaches after a reconnect.
public actor AcpmuxFeed: ConversationFeed {
    /// Updates in order until ``close()``.
    public nonisolated let updates: AsyncStream<FeedUpdate>
    private let continuation: AsyncStream<FeedUpdate>.Continuation
    private let sessionID: String
    private let pageSize: Int
    private let decoder = AcpmuxEventDecoder()
    private weak var connection: AcpmuxConnection?
    private var client: AcpmuxRPCClient?
    private var lastSeq: UInt64 = 0
    private var oldestSeq: UInt64?
    private var attachedOnce = false
    private var backfilling = false
    private var held: [AcpmuxRecord] = []
    private var closed = false

    init(sessionID: String, pageSize: Int, connection: AcpmuxConnection) {
        self.sessionID = sessionID
        self.pageSize = pageSize
        self.connection = connection
        let (s, c) = AsyncStream<FeedUpdate>.makeStream(bufferingPolicy: .unbounded)
        // Unbounded on purpose: the consumer is the main-actor model folding
        // every update; dropping one would corrupt the timeline. Each element
        // is one page or one event, and pages are capped by pageSize.
        updates = s
        continuation = c
    }

    private func records(_ v: JSONValue?) -> [AcpmuxRecord] {
        (v?.arrayValue ?? []).compactMap(AcpmuxRecord.init(event:))
    }

    private func emit(_ records: [AcpmuxRecord], hasOlder: Bool?) {
        if let max = records.map(\.seq).max(), max > lastSeq { lastSeq = max }
        if let min = records.map(\.seq).min() { oldestSeq = oldestSeq.map { Swift.min($0, min) } ?? min }
        let envs = decoder.decode(records)
        if !envs.isEmpty || hasOlder != nil {
            continuation.yield(.events(envs, hasOlder: hasOlder))
        }
    }

    /// The control connection is up: attach (first time: newest page; later:
    /// resume after the cursor).
    func connected(_ client: AcpmuxRPCClient) async {
        guard !closed else { return }
        self.client = client
        do {
            if !attachedOnce {
                let r = try await client.request("_acpmux/attach", .object(["sessionId": .string(sessionID), "limit": .number(Double(pageSize))]))
                if let s = r["session"] { continuation.yield(.metadata(decoder.metadata(s))) }
                emit(records(r["events"]), hasOlder: r["more"]?.boolValue ?? false)
                attachedOnce = true
            } else {
                let r = try await client.request("_acpmux/attach", .object(["sessionId": .string(sessionID), "afterSeq": .number(Double(lastSeq)), "limit": .number(2000)]))
                if let s = r["session"] { continuation.yield(.metadata(decoder.metadata(s))) }
                emit(records(r["events"]), hasOlder: nil)
                if r["more"]?.boolValue == true { await backfill() }
                continuation.yield(.reconnected)
            }
        } catch {
            // The connection's loop reconnects and calls again.
        }
    }

    func disconnected() {
        client = nil
    }

    /// A live notification for this session.
    func handle(_ n: AcpmuxNotification) async {
        let record: AcpmuxRecord?
        switch n.method {
        case "session/update": record = AcpmuxRecord(update: n.params)
        case "_acpmux/event": record = AcpmuxRecord(event: n.params)
        default: record = nil
        }
        guard let record, attachedOnce else { return }
        if backfilling {
            held.append(record)
            return
        }
        if record.seq <= lastSeq { return }
        if record.seq > lastSeq + 1 {
            held.append(record)
            await backfill()
            return
        }
        emit([record], hasOlder: nil)
    }

    /// Replays everything after the cursor (a gap, or a lagged notice).
    func backfill() async {
        guard !backfilling, let client else { return }
        backfilling = true
        defer { backfilling = false }
        while true {
            guard let r = try? await client.request("_acpmux/events", .object(["sessionId": .string(sessionID), "afterSeq": .number(Double(lastSeq)), "limit": .number(2000)])) else { break }
            emit(records(r["events"]), hasOlder: nil)
            if r["more"]?.boolValue != true { break }
        }
        let pending = held.filter { $0.seq > lastSeq }.sorted { $0.seq < $1.seq }
        held.removeAll()
        if !pending.isEmpty { emit(pending, hasOlder: nil) }
    }

    func metadata(_ m: ConversationMetadata) {
        continuation.yield(.metadata(m))
    }

    func deleted() {
        continuation.yield(.events([ConversationEnvelope(cursor: ConversationCursor(order: .max), timestamp: nil, event: .deleted)], hasOlder: nil))
    }

    /// Loads the page before the oldest loaded event.
    /// - Parameter pageSize: The most events to load.
    /// - Throws: When acpmux cannot be reached.
    public func loadOlder(pageSize: Int) async throws {
        guard let client, let oldest = oldestSeq, oldest > 1 else { return }
        let r = try await client.request("_acpmux/events", .object(["sessionId": .string(sessionID), "beforeSeq": .number(Double(oldest)), "limit": .number(Double(pageSize))]))
        emit(records(r["events"]), hasOlder: r["more"]?.boolValue ?? false)
    }

    /// Detaches from the session and ends ``updates``.
    public func close() async {
        guard !closed else { return }
        closed = true
        if let client {
            _ = try? await client.request("_acpmux/detach", .object(["sessionId": .string(sessionID)]), timeout: .seconds(2))
        }
        await connection?.unregister(sessionID)
        continuation.finish()
    }
}
