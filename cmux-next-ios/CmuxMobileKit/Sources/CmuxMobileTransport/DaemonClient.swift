import Foundation

/// Request/response and event client for the cmux-tui daemon protocol (v12,
/// JSON lines) carried on a link's `daemon` channel.
public actor DaemonClient {
    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    /// Ids of a batch sent but not yet awaited, and replies that came first.
    private var expected: Set<String> = []
    private var early: [String: Data] = [:]
    /// Set once the channel ended; later waits fail with it.
    private var ended: (any Error)?
    private var buffer = Data()
    private var readTask: Task<Void, Never>?
    public nonisolated let events: AsyncStream<Data>
    private let eventContinuation: AsyncStream<Data>.Continuation

    /// The `LinkError` code of a request whose deadline passed.
    public static let replyTimeout = "reply_timeout"

    public init(channel: any LinkChannel) {
        self.channel = channel
        (events, eventContinuation) = AsyncStream.makeStream()
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
    /// With `deadline`, a reply that has not come by then fails with
    /// `LinkError` `reply_timeout` (a late reply is dropped).
    public func request(_ cmd: String, params: [String: Any] = [:], deadline: Duration? = nil,
                        clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        start()
        let id = nextRequestID()
        let line = try line(id: id, cmd: cmd, params: params)
        if let deadline {
            Task { [weak self] in
                try? await clock.sleep(for: deadline)
                await self?.fail(id: id, error: LinkError(code: Self.replyTimeout, message: "no reply to \(cmd) in time"))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await channel.send(line) } catch { self.fail(id: id, error: error) }
            }
        }
    }

    /// Closes the channel (the Mac drops its daemon connection) and fails
    /// every request still waiting.
    public func close() async {
        readTask?.cancel()
        await channel.close(code: "eof", reason: "")
        finish(LinkError(code: "closed", message: "daemon channel closed"))
    }

    /// Sends a `cmux.protocol/2` request (`machine` and `session` default to
    /// `current`, as the Mac app's `ResourceRequestEnvelope`) and returns the
    /// raw response line (`ok`, `result` or `error`).
    ///
    /// With `deadline`, a reply that has not come by then fails with
    /// `LinkError` `reply_timeout` (a late reply is dropped as an event), so
    /// a request on a link that went quiet never waits forever.
    public func resourceRequest(_ operation: String, params: sending [String: Any] = [:], idempotencyKey: String? = nil,
                                deadline: Duration? = nil, clock: any Clock<Duration> = ContinuousClock()) async throws -> Data {
        start()
        let id = "r\(nextID)"
        nextID += 1
        if let deadline {
            Task { [weak self] in
                try? await clock.sleep(for: deadline)
                await self?.fail(id: id, error: LinkError(code: Self.replyTimeout, message: "no reply to \(operation) in time"))
            }
        }
        var fields = params
        fields["machine"] = fields["machine"] ?? "current"
        fields["session"] = fields["session"] ?? "current"
        var object: [String: Any] = ["protocol": "cmux.protocol/2", "type": "request", "id": id, "operation": operation, "params": fields]
        if let idempotencyKey { object["idempotency_key"] = idempotencyKey }
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await channel.send(line) } catch { self.fail(id: id, error: error) }
            }
        }
    }

    /// Sends every request in one write, in order, and returns their replies
    /// in the same order: one round trip instead of one per request (the
    /// daemon handles a connection's lines in order). A failed request is a
    /// `.failure` in its slot; a failed write fails them all.
    public func requests(_ batch: [(cmd: String, params: [String: Any])]) async -> [Result<Data, any Error>] {
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
        expected.formUnion(ids)
        do { try await channel.send(bytes) } catch {
            for id in ids {
                expected.remove(id)
                early[id] = nil
            }
            return ids.map { _ in .failure(error) }
        }
        var results: [Result<Data, any Error>] = []
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
    public func submit(_ cmd: String, params: [String: Any] = [:]) async throws -> String {
        start()
        let id = nextRequestID()
        let line = try line(id: id, cmd: cmd, params: params)
        expected.insert(id)
        do { try await channel.send(line) } catch {
            expected.remove(id)
            early[id] = nil
            throw error
        }
        return id
    }

    /// The reply to a ``submit(_:params:)``ed request, which may already have come.
    public func reply(to id: String) async throws -> Data {
        try await reply(id)
    }

    /// The reply to batch request `id`, which may already have come.
    private func reply(_ id: String) async throws -> Data {
        if let line = early.removeValue(forKey: id) { return line }
        if let ended {
            expected.remove(id)
            throw ended
        }
        return try await withCheckedThrowingContinuation { continuation in
            expected.remove(id)
            pending[id] = continuation
        }
    }

    private func fail(id: String, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func readLoop() async {
        do {
            while let chunk = try await channel.receive() {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    route(Data(line))
                }
            }
            finish(LinkError(code: "closed", message: "daemon channel closed"))
        } catch {
            finish(error)
        }
    }

    private func route(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String else {
            eventContinuation.yield(line)
            return
        }
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: line)
        } else if expected.remove(id) != nil {
            early[id] = line
        } else {
            eventContinuation.yield(line)
        }
    }

    private func finish(_ error: any Error) {
        ended = error
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        eventContinuation.finish()
    }
}
