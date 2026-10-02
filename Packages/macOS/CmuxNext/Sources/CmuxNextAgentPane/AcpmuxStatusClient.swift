import Foundation
import Network

/// Asks a running acpmux daemon for its WebSocket endpoint over the unix
/// socket: `initialize`, then `_acpmux/status`, whose `webUrl` carries the
/// port and token. JSON-RPC 2.0, one JSON object per line. Network.framework
/// keeps every read and write off the caller's thread.
nonisolated enum AcpmuxStatusClient {
    nonisolated enum Failure: Error, Equatable {
        case unreachable(String)
        case closed
        case rpc(String)
        case noWebSocket
    }

    /// The endpoint of the daemon listening on `socketPath`. Throws
    /// `.unreachable` when nothing answers there (start one then).
    @concurrent static func endpoint(socketPath: String, deadline: Duration = .seconds(2)) async throws -> AcpmuxWebEndpoint {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        let webURL = try await withAgentPaneDeadline(deadline, label: "acpmux status", onTimeout: { connection.cancel() }) {
            try await exchange(on: connection)
        }
        guard let webURL, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw Failure.noWebSocket
        }
        return endpoint
    }

    /// The status reply's `webUrl`, nil when the daemon reports none (its
    /// WebSocket listener failed to bind).
    private static func exchange(on connection: NWConnection) async throws -> String? {
        try await start(connection)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-agent-pane", "version": "1"], "clientCapabilities": [:]],
        ]
        let status: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/status", "params": [:]]
        var payload = Data()
        for request in [initialize, status] {
            payload += try JSONSerialization.data(withJSONObject: request)
            payload.append(0x0A)
        }
        try await send(payload, on: connection)
        var buffer = Data()
        // Reads until the status reply; notifications and the initialize reply are skipped.
        while true {  // wakeup-allow: each pass awaits socket data; EOF, error or the deadline ends it
            guard let chunk = try await receive(on: connection) else { throw Failure.closed }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let reply = try reply(to: 2, in: Data(line)) { return reply["webUrl"] as? String }
            }
            if buffer.count > 1 << 20 { throw Failure.rpc("status reply too large") }
        }
    }

    /// The `result` of the reply to `id` in `line`, nil for any other message.
    static func reply(to id: Int, in line: Data) throws -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["id"] as? NSNumber)?.intValue == id else { return nil }
        if let error = object["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "acpmux request failed")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private static func start(_ connection: NWConnection) async throws {
        let gate = AgentPaneResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    gate.run { continuation.resume(throwing: Failure.unreachable("\(error)")) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "cmux.next.agent-pane.acpmux-status"))
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)  // EOF
                }
            }
        }
    }
}
