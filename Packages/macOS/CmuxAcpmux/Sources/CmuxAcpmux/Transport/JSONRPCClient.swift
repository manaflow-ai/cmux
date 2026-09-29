import Foundation

/// A JSON-RPC 2.0 client over one newline-framed byte connection.
///
/// Correlates responses to requests by integer id and publishes notifications on
/// ``notifications``. When the connection ends, every pending request fails with
/// ``JSONRPCClientError/disconnected`` and ``notifications`` finishes.
public actor JSONRPCClient {
    /// Server notifications in arrival order.
    public nonisolated let notifications: AsyncStream<JSONRPCNotification>
    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation
    private let writer: @Sendable (Data) throws -> Void
    private let closer: @Sendable () -> Void
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextID = 1
    private var framer = LineFramer()
    private var isClosed = false
    private var readTask: Task<Void, Never>?

    /// Creates a client over an already-connected byte stream.
    /// - Parameters:
    ///   - inbound: Raw bytes from the peer.
    ///   - write: Writes one encoded frame to the peer.
    ///   - close: Closes the underlying connection.
    public init(
        inbound: AsyncStream<Data>,
        write: @escaping @Sendable (Data) throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        var continuation: AsyncStream<JSONRPCNotification>.Continuation!
        notifications = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        notificationContinuation = continuation
        writer = write
        closer = close
        Task { await self.startReading(inbound) }
    }

    /// Creates a client connected to a Unix socket.
    /// - Throws: ``UnixSocketError`` when the connection fails.
    public init(socketPath: String) throws {
        let connection = try UnixSocketConnection(path: socketPath)
        self.init(
            inbound: connection.chunks,
            write: { try connection.write($0) },
            close: { connection.close() }
        )
    }

    private func startReading(_ inbound: AsyncStream<Data>) {
        readTask = Task { [weak self] in
            for await chunk in inbound {
                guard let self else { return }
                await self.consume(chunk)
            }
            await self?.finish()
        }
    }

    private func consume(_ chunk: Data) {
        let lines: [Data]
        do {
            lines = try framer.append(chunk)
        } catch {
            finish()
            return
        }
        for line in lines {
            guard let message = try? JSONRPCInbound.decode(line) else { continue }
            switch message {
            case .response(let id, let result):
                guard let continuation = pending.removeValue(forKey: id) else { continue }
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            case .notification(let method, let params):
                notificationContinuation.yield(JSONRPCNotification(method: method, params: params))
            case .request:
                continue
            }
        }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: JSONRPCClientError.disconnected)
        }
        notificationContinuation.finish()
        closer()
    }

    /// Whether the connection has ended.
    public var isConnected: Bool { !isClosed }

    /// Sends a request and waits for its result.
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: Encodable parameters.
    /// - Returns: The raw `result` value.
    /// - Throws: ``JSONRPCError`` for an error response, ``JSONRPCClientError`` for transport failure.
    public func request<Params: Encodable & Sendable>(_ method: String, params: Params) async throws -> JSONValue {
        guard !isClosed else { throw JSONRPCClientError.disconnected }
        let id = nextID
        nextID += 1
        let payload = try JSONEncoder().encode(JSONRPCOutboundRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try writer(LineFramer.frame(payload))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: JSONRPCClientError.disconnected)
            }
        }
    }

    /// Sends a request and decodes its result.
    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params,
        as type: Result.Type
    ) async throws -> Result {
        let value = try await request(method, params: params)
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// Sends a notification (a request without an id). acpmux requires this form for `session/cancel`.
    /// - Throws: ``JSONRPCClientError/disconnected`` when the connection is closed.
    public func notify<Params: Encodable & Sendable>(_ method: String, params: Params) throws {
        guard !isClosed else { throw JSONRPCClientError.disconnected }
        let payload = try JSONEncoder().encode(JSONRPCOutboundNotification(method: method, params: params))
        do {
            try writer(LineFramer.frame(payload))
        } catch {
            throw JSONRPCClientError.disconnected
        }
    }

    /// Closes the connection and fails pending requests.
    public func close() {
        readTask?.cancel()
        finish()
    }
}

/// A server-to-client notification.
public struct JSONRPCNotification: Sendable, Equatable {
    /// The method name, for example `_acpmux/event`.
    public var method: String
    /// The raw params.
    public var params: JSONValue
}

/// Transport-level client errors.
public enum JSONRPCClientError: Error, Sendable, Equatable {
    /// The connection closed before a response arrived.
    case disconnected
}
