import CmuxConversation
import Foundation

/// JSON-RPC 2.0 over newline-delimited JSON on one byte stream to acpmux.
///
/// Requests carry a deadline (control requests should never hang); a request
/// whose answer arrives much later (a prompt answers when its turn ends) is
/// sent with ``fire(_:_:)`` and its outcome read from events instead.
/// Notifications stream in order. If the consumer falls so far behind that
/// the buffer overflows, a synthetic `_acpmux/lagged` with no session ids
/// follows, meaning "replay everything".
actor AcpmuxRPCClient {
    private let stream: any ConversationByteStream
    private let clock: any Clock<Duration>
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var failure: (any Error)?
    private var overflowed = false
    nonisolated let notifications: AsyncStream<AcpmuxNotification>
    private let notify: AsyncStream<AcpmuxNotification>.Continuation

    /// Notifications held for a slow consumer before falling back to a replay.
    static let notificationBuffer = 20_000

    init(stream: any ConversationByteStream, clock: any Clock<Duration>) {
        self.stream = stream
        self.clock = clock
        let (s, c) = AsyncStream<AcpmuxNotification>.makeStream(bufferingPolicy: .bufferingOldest(Self.notificationBuffer))
        notifications = s
        notify = c
    }

    /// Starts reading. The notification stream finishes when the connection ends.
    func start() {
        guard readTask == nil else { return }
        readTask = Task { [stream] in
            var framer = LineFramer()
            do {
                while let chunk = try await stream.read(maximumBytes: 256 * 1024) {
                    for line in try framer.append(chunk) {
                        self.received(line)
                    }
                }
                self.finish(ConversationBackendError.unreachable("acpmux closed the connection"))
            } catch {
                self.finish(ConversationBackendError.unreachable(String(describing: error)))
            }
        }
    }

    private func received(_ line: Data) {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        if let method = v["method"]?.stringValue {
            if v["id"] != nil, v["id"] != .null {
                return // acpmux sends clients no requests
            }
            deliver(AcpmuxNotification(method: method, params: v["params"] ?? .null))
            return
        }
        guard let id = v["id"]?.uint64Value.map(Int.init), let c = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if let e = v["error"], e != .null {
            c.resume(throwing: ConversationBackendError.refused(code: Int(e["code"]?.numberValue ?? 0), message: e["message"]?.stringValue ?? "error"))
        } else {
            c.resume(returning: v["result"] ?? .null)
        }
    }

    private func deliver(_ n: AcpmuxNotification) {
        if overflowed {
            if case .enqueued = notify.yield(AcpmuxNotification(method: "_acpmux/lagged", params: .object(["sessionIds": .null, "watch": .bool(true)]))) {
                overflowed = false
            } else {
                return
            }
        }
        if case .dropped = notify.yield(n) {
            overflowed = true
        }
    }

    private func finish(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        for (_, c) in pending {
            c.resume(throwing: error)
        }
        pending.removeAll()
        for (_, t) in deadlines {
            t.cancel()
        }
        deadlines.removeAll()
        notify.finish()
    }

    private func line(_ value: JSONValue) throws -> Data {
        var d = try JSONEncoder().encode(value)
        d.append(0x0A)
        return d
    }

    /// Sends a request and waits for its answer.
    /// - Parameters:
    ///   - method: The method.
    ///   - params: The parameters.
    ///   - timeout: Deadline; a miss throws ``ConversationBackendError/timedOut``.
    /// - Returns: The result.
    func request(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(15)) async throws -> JSONValue {
        if let failure { throw failure }
        nextID += 1
        let id = nextID
        let data = try line(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            deadlines[id] = Task { [clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                self.expire(id)
            }
            Task {
                do {
                    try await self.stream.write(data)
                } catch {
                    self.fail(id, ConversationBackendError.unreachable(String(describing: error)))
                }
            }
        }
    }

    private func expire(_ id: Int) {
        fail(id, ConversationBackendError.timedOut)
    }

    private func fail(_ id: Int, _ error: any Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Sends a request whose answer is not awaited (it may come much later).
    /// - Parameters:
    ///   - method: The method.
    ///   - params: The parameters.
    /// - Throws: When it cannot be written.
    func fire(_ method: String, _ params: JSONValue) async throws {
        if let failure { throw failure }
        nextID += 1
        try await stream.write(line(.object(["jsonrpc": .string("2.0"), "id": .number(Double(nextID)), "method": .string(method), "params": params])))
    }

    /// Sends a notification.
    /// - Parameters:
    ///   - method: The method.
    ///   - params: The parameters.
    /// - Throws: When it cannot be written.
    func notify(_ method: String, _ params: JSONValue) async throws {
        if let failure { throw failure }
        try await stream.write(line(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])))
    }

    /// Closes the connection.
    func close() async {
        readTask?.cancel()
        await stream.close()
        finish(ConversationBackendError.unreachable("closed"))
    }
}
