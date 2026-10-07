public import CmuxMobileWire
import Foundation
import Network
import Synchronization

/// `AcpmuxRPC` over acpmux's unix socket: one JSON object per line, an
/// `initialize` first, replies matched by id. Network.framework keeps reads
/// and writes off the cooperative pool. The connection ends when the socket
/// closes; every pending call then fails.
public actor AcpmuxSocketRPC: AcpmuxRPC {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cmux.next.mobile-link.acpmux")
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var sinks: [UUID: AsyncStream<AcpmuxMessage>.Continuation] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false

    /// Connects and initializes; throws when no daemon answers at `socketPath`.
    public static func connect(socketPath: String, clientName: String = "cmux-next-mobile-link") async throws -> AcpmuxSocketRPC {
        let rpc = AcpmuxSocketRPC(connection: NWConnection(to: .unix(path: socketPath), using: .tcp))
        try await rpc.open()
        _ = try await rpc.call("initialize", params: .object([
            "protocolVersion": .int(1), "clientInfo": .object(["name": .string(clientName), "version": .string("1")]),
            "clientCapabilities": .object([:]),
        ]))
        return rpc
    }

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard !closed else { throw AcpmuxRPCError("the acpmux connection closed") }
        let id = nextID
        nextID += 1
        let line = try Self.line(["jsonrpc": .string("2.0"), "id": .int(Int64(id)), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await self.write(line, failing: id) }
        }
    }

    public func notify(_ method: String, params: JSONValue) async throws {
        guard !closed else { throw AcpmuxRPCError("the acpmux connection closed") }
        try await send(try Self.line(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    public func messages() -> AsyncStream<AcpmuxMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: AcpmuxMessage.self, bufferingPolicy: .bufferingNewest(512))
        guard !closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        sinks[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropSink(id) } }
        return stream
    }

    public func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        connection.cancel()
        let calls = pending
        pending = [:]
        for continuation in calls.values { continuation.resume(throwing: AcpmuxRPCError("the acpmux connection closed")) }
        for sink in sinks.values { sink.finish() }
        sinks = [:]
    }

    // MARK: Private

    private func open() async throws {
        let connection = connection
        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    gate.run { continuation.resume(throwing: AcpmuxRPCError("acpmux is unreachable: \(error)")) }
                case .cancelled: gate.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        reader = Task { [weak self] in await self?.readLoop() }
    }

    private func readLoop() async {
        var buffer = Data()
        // wakeup-allow: each pass awaits socket data; EOF, an error or close() ends it.
        while !Task.isCancelled {
            guard let chunk = try? await receive() else { break }
            if chunk.isEmpty { continue }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line)
            }
            if buffer.count > 8 << 20 { break }
        }
        close()
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        if let method = message["method"]?.stringValue {
            let item = AcpmuxMessage(method: method, params: message["params"] ?? .object([:]), isRequest: message["id"] != nil)
            for sink in sinks.values { sink.yield(item) }
            return
        }
        guard case .int(let raw)? = message["id"], let continuation = pending.removeValue(forKey: Int(raw)) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: AcpmuxRPCError(error["message"]?.stringValue ?? "acpmux request failed"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func write(_ data: Data, failing id: Int) async {
        do {
            try await send(data)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive() async throws -> Data? {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    private func dropSink(_ id: UUID) { sinks[id] = nil }

    private static func line(_ object: [String: JSONValue]) throws -> Data {
        var data = try JSONValue.object(object).canonicalData()
        data.append(0x0A)
        return data
    }
}

/// Runs a continuation's resume once (Network.framework reports several states).
private final class ResumeGate: Sendable {
    private let done = Mutex(false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
