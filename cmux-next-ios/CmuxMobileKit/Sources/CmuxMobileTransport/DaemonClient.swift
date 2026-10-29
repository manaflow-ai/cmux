import Foundation

/// Request/response and event client for the cmux-tui daemon protocol (v12,
/// JSON lines) carried on a link's `daemon` channel.
public actor DaemonClient {
    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [String: CheckedContinuation<ReceivedLine, any Error>] = [:]
    /// Ids of a batch sent but not yet awaited, and replies that came first.
    private var expected: Set<String> = []
    private var early: [String: Result<ReceivedLine, any Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    /// Set once the channel ended; later waits fail with it.
    private var ended: (any Error)?
    private var buffer = Data()
    private var readTask: Task<Void, Never>?
    /// Unsolicited daemon events (terminal output, tree notifications, etc.).
    /// The sequence is byte-bounded; when its consumer falls behind, the
    /// daemon reader waits before reading another channel frame so link-level
    /// backpressure reaches the Mac.
    public nonisolated let events: DaemonEventStream
    private let eventBuffer: BoundedDaemonEventBuffer

    /// The `LinkError` code of a request whose deadline passed.
    public static let replyTimeout = "reply_timeout"
    public static let defaultDeadline: Duration = .seconds(15)

    public struct ReceivedLine: Sendable {
        public let data: Data
        public let sequence: UInt64
    }
    public nonisolated let orderedEvents: AsyncStream<ReceivedLine>
    private let orderedContinuation: AsyncStream<ReceivedLine>.Continuation
    private let usesOrderedEvents: Bool
    private var sequence: UInt64 = 0
    public var receivedPosition: UInt64 { sequence }

    public init(channel: any LinkChannel, orderedEvents: Bool = false, eventCapacity: Int = BoundedDaemonEventBuffer.defaultCapacity) {
        self.channel = channel
        let eventBuffer = BoundedDaemonEventBuffer(capacity: eventCapacity, initiallyClosed: orderedEvents)
        self.eventBuffer = eventBuffer
        self.events = DaemonEventStream(buffer: eventBuffer)
        (self.orderedEvents, orderedContinuation) = AsyncStream.makeStream()
        usesOrderedEvents = orderedEvents
        if !orderedEvents { orderedContinuation.finish() }
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task { await self.readLoop() }
    }

    private func line(id: String, cmd: String, params: [String: Any]) throws -> Data {
        var object = params
        object["id"] = id
        object["cmd"] = cmd
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        return line
    }

    private func nextRequestID() -> String {
        defer { nextID += 1 }
        return "m\(nextID)"
    }

    /// Sends `{"id", "cmd", ...params}` and returns the raw JSON reply line.
    /// The default deadline is 15 seconds. A reply that has not come by then fails with
    /// `LinkError` `reply_timeout` (a late reply is dropped).
    public func request(_ cmd: String, params: [String: Any] = [:], deadline: Duration? = nil,
                        clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        try await requestOrdered(cmd, params: params, deadline: deadline, clock: clock).data
    }

    public func requestOrdered(_ cmd: String, params: [String: Any] = [:], deadline: Duration? = nil,
                               clock: any Clock<Duration> = ContinuousClock()) async throws -> ReceivedLine {
        start()
        let id = nextRequestID()
        let line = try line(id: id, cmd: cmd, params: params)
        return try await perform(id: id, line: line, deadline: deadline ?? Self.defaultDeadline, clock: clock)
    }

    /// Closes the channel (the Mac drops its daemon connection) and fails
    /// every request still waiting.
    public func close() async {
        readTask?.cancel()
        await channel.close(code: "eof", reason: "")
        await finish(LinkError(code: "closed", message: "daemon channel closed"))
    }

    /// Sends a `cmux.protocol/2` request (`machine` and `session` default to
    /// `current`, as the Mac app's `ResourceRequestEnvelope`) and returns the
    /// raw response line (`ok`, `result` or `error`).
    ///
    /// The default deadline is 15 seconds. A reply that has not come by then fails with
    /// `LinkError` `reply_timeout` (a late reply is dropped), so
    /// a request on a link that went quiet never waits forever.
    public func resourceRequest(_ operation: String, params: sending [String: Any] = [:], idempotencyKey: String? = nil,
                                deadline: Duration? = nil, clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        start()
        let id = "r\(nextID)"
        nextID += 1
        var fields = params
        fields["machine"] = fields["machine"] ?? "current"
        fields["session"] = fields["session"] ?? "current"
        var object: [String: Any] = ["protocol": "cmux.protocol/2", "type": "request", "id": id, "operation": operation, "params": fields]
        if let idempotencyKey { object["idempotency_key"] = idempotencyKey }
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        return try await perform(id: id, line: line, deadline: deadline ?? Self.defaultDeadline, clock: clock).data
    }

    private func perform(id: String, line: Data, deadline: Duration, clock: any Clock<Duration>) async throws -> ReceivedLine {
        try Task.checkCancellation()
        if let ended { throw ended }
        expected.insert(id)
        arm(id: id, deadline: deadline, clock: clock)
        let write = Task { await self.send(line, ids: [id]) }
        defer { write.cancel() }
        return try await reply(id)
    }

    private func arm(id: String, deadline: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        deadlines[id] = Task { await self.expire(id, after: deadline, clock: clock) }
    }

    private func expire(_ id: String, after deadline: Duration, clock: any Clock<Duration>) async {
        do { try await clock.sleep(for: deadline) } catch { return }
        guard !Task.isCancelled else { return }
        fail(id: id, error: LinkError(code: Self.replyTimeout, message: "The Mac didn't answer. Retry."))
    }

    /// Sends every request in one write, in order, and returns their replies
    /// in the same order: one round trip instead of one per request (the
    /// daemon handles a connection's lines in order). A failed request is a
    /// `.failure` in its slot; a failed write fails them all.
    public func requests(_ batch: [(cmd: String, params: [String: Any])],
                         deadline: Duration = DaemonClient.defaultDeadline) async -> [Result<Data, any Error>] {
        await requestsOrdered(batch, deadline: deadline).map { $0.map(\.data) }
    }

    public func requestsOrdered(_ batch: [(cmd: String, params: [String: Any])],
                                deadline: Duration = DaemonClient.defaultDeadline) async -> [Result<ReceivedLine, any Error>] {
        start()
        var ids: [String] = []
        var bytes = Data()
        for item in batch {
            let id = nextRequestID()
            do { bytes.append(try line(id: id, cmd: item.cmd, params: item.params)) } catch {
                return batch.map { _ in .failure(error) }
            }
            ids.append(id)
        }
        guard !Task.isCancelled else { return ids.map { _ in .failure(CancellationError()) } }
        if let ended { return ids.map { _ in .failure(ended) } }
        expected.formUnion(ids)
        for id in ids { arm(id: id, deadline: deadline) }
        let write = Task { await self.send(bytes, ids: ids) }
        defer { write.cancel() }
        var results: [Result<ReceivedLine, any Error>] = []
        for id in ids {
            do { results.append(.success(try await reply(id))) } catch { results.append(.failure(error)) }
        }
        return results
    }

    /// Writes one request and returns its id once the write is done, without
    /// waiting for the reply (``reply(to:)``). A caller that awaits each
    /// submit before the next keeps its requests in order on the channel
    /// while several are unanswered (the daemon handles a connection's lines
    /// in order).
    public func submit(_ cmd: String, params: [String: Any] = [:],
                       deadline: Duration = DaemonClient.defaultDeadline) async throws -> String {
        start()
        let id = nextRequestID()
        let line = try line(id: id, cmd: cmd, params: params)
        try Task.checkCancellation()
        if let ended { throw ended }
        expected.insert(id)
        arm(id: id, deadline: deadline)
        do {
            let channel = self.channel
            try await LinkDeadline.run(timeout: deadline,
                                       timeoutError: LinkError(code: "write_timeout", message: "The Mac didn't answer. Retry."),
                                       operation: { try await channel.send(line) },
                                       onCancel: { await channel.close(code: "timeout", reason: "write interrupted") })
        } catch {
            discard(id)
            throw error
        }
        return id
    }

    /// The reply to a ``submit(_:params:)``ed request, which may already have come.
    public func reply(to id: String) async throws -> Data {
        try await reply(id).data
    }

    /// The reply to batch request `id`, which may already have come.
    private func reply(_ id: String) async throws -> ReceivedLine {
        try await withTaskCancellationHandler {
            try await self.waitForReply(id)
        } onCancel: {
            self.cancelReply(id)
        }
    }

    private nonisolated func cancelReply(_ id: String) {
        Task { await self.fail(id: id, error: CancellationError()) }
    }

    private func waitForReply(_ id: String) async throws -> ReceivedLine {
        if Task.isCancelled {
            discard(id)
            throw CancellationError()
        }
        if let result = early.removeValue(forKey: id) { return try result.get() }
        if let ended {
            discard(id)
            throw ended
        }
        guard expected.contains(id) else {
            throw LinkError(code: "unknown_request", message: "Request is no longer waiting")
        }
        return try await withCheckedThrowingContinuation { continuation in
            registerReply(id, continuation)
        }
    }

    private func registerReply(_ id: String, _ continuation: CheckedContinuation<ReceivedLine, any Error>) {
        expected.remove(id)
        pending[id] = continuation
    }

    private func send(_ data: Data, ids: [String]) async {
        do {
            try Task.checkCancellation()
            try await channel.send(data)
        } catch {
            for id in ids { fail(id: id, error: error) }
        }
    }

    private func discard(_ id: String) {
        deadlines.removeValue(forKey: id)?.cancel()
        expected.remove(id)
        early[id] = nil
    }

    private func fail(id: String, error: any Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        if let waiter = pending.removeValue(forKey: id) {
            waiter.resume(throwing: error)
        } else if expected.remove(id) != nil {
            early[id] = .failure(error)
        }
    }

    private func readLoop() async {
        do {
            while let chunk = try await channel.receive() {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    await route(Data(line))
                }
            }
            await finish(LinkError(code: "closed", message: "daemon channel closed"))
        } catch {
            await finish(error)
        }
    }

    private func route(_ line: Data) async {
        guard !line.isEmpty else { return }
        sequence += 1
        let received = ReceivedLine(data: line, sequence: sequence)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String else {
            await yieldEvent(received)
            return
        }
        deadlines.removeValue(forKey: id)?.cancel()
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: received)
        } else if expected.remove(id) != nil {
            early[id] = .success(received)
        } else if !(id.hasPrefix("m") || id.hasPrefix("r")) || Int(id.dropFirst()) == nil {
            await yieldEvent(received)
        }
    }

    private func yieldEvent(_ received: ReceivedLine) async {
        if usesOrderedEvents { orderedContinuation.yield(received) }
        else { _ = await eventBuffer.push(received.data) }
    }

    private func finish(_ error: any Error) async {
        ended = error
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        for task in deadlines.values { task.cancel() }
        deadlines.removeAll()
        expected.removeAll()
        early.removeAll()
        orderedContinuation.finish()
        await eventBuffer.finish()
    }
}
