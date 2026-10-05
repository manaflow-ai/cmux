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
        try await status(socketPath: socketPath, deadline: deadline).endpoint()
    }

    /// The running daemon's `_acpmux/status`. Throws `.unreachable` when
    /// nothing answers there.
    @concurrent static func status(socketPath: String, deadline: Duration = .seconds(2)) async throws -> AcpmuxStatus {
        let result = try await call(socketPath: socketPath, method: "_acpmux/status", deadline: deadline)
        return AcpmuxStatus(result)
    }

    /// `_acpmux/shutdown`: the daemon stops; agents under agent hosts keep
    /// running for the next daemon. With `endAgents` (Quit Everything) they
    /// end, except the agents of `keepSessions`.
    @concurrent static func shutdown(socketPath: String, endAgents: Bool = false, keepSessions: [String] = [],
                                     deadline: Duration = .seconds(2)) async throws {
        let params: [String: any Sendable] = endAgents ? ["endAgents": true, "keepSessions": keepSessions] : [:]
        _ = try await call(socketPath: socketPath, method: "_acpmux/shutdown", params: params, deadline: deadline)
    }

    /// `_acpmux/sessions`: every session's summary.
    @concurrent static func sessions(socketPath: String, deadline: Duration) async throws -> ResultBox {
        ResultBox(try await call(socketPath: socketPath, method: "_acpmux/sessions", deadline: deadline))
    }

    /// `_acpmux/web_modes {sessionId}` (read-only, unix socket only; the daemon lane adds it): whether
    /// `mode` is in the asking table (`web_modes.rs`, config included) for the session's family.
    /// Nil when the daemon cannot tell (no such op yet, no such session, an unknown family).
    @concurrent static func modeAsks(socketPath: String, sessionId: String?, mode: String, deadline: Duration = .seconds(2)) async -> Bool? {
        var params: [String: any Sendable] = [:]
        if let sessionId { params["sessionId"] = sessionId }
        guard let result = try? await call(socketPath: socketPath, method: "_acpmux/web_modes", params: params, deadline: deadline),
              let families = result["families"] as? [String: [String]],
              let family = (result["session"] as? [String: Any])?["family"] as? String,
              let asking = families[family] else { return nil }
        return asking.contains(mode)
    }

    private static func call(socketPath: String, method: String, params: [String: any Sendable] = [:],
                             deadline: Duration) async throws -> [String: Any] {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        let box = try await withAgentPaneDeadline(deadline, label: "acpmux \(method)", onTimeout: { connection.cancel() }) {
            ResultBox(try await exchange(method, params: params, on: connection))
        }
        return box.value
    }

    /// `initialize`, then `method`; returns its result.
    private static func exchange(_ method: String, params: [String: any Sendable], on connection: NWConnection) async throws -> [String: Any] {
        try await start(connection)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-agent-pane", "version": "1"], "clientCapabilities": [:]],
        ]
        let status: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": method, "params": params]
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
                if let reply = try reply(to: 2, in: Data(line)) { return reply }
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

/// A JSON result handed across the deadline boundary.
nonisolated struct ResultBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The fields of `_acpmux/status` the app reads.
nonisolated struct AcpmuxStatus: Sendable, Equatable {
    var webURL: String?
    var build: String?
    var pid: Int32?
    /// The daemon runs agents under agent hosts: a restart keeps them.
    var agentHosts: Bool

    init(webURL: String? = nil, build: String? = nil, pid: Int32? = nil, agentHosts: Bool = false) {
        self.webURL = webURL
        self.build = build
        self.pid = pid
        self.agentHosts = agentHosts
    }

    init(_ result: [String: Any]) {
        webURL = result["webUrl"] as? String
        build = result["build"] as? String
        pid = (result["pid"] as? NSNumber).map { Int32(truncating: $0) }
        agentHosts = (result["agentHosts"] as? Bool) ?? false
    }

    /// The WebSocket endpoint; `.noWebSocket` when the listener failed to bind.
    func endpoint() throws -> AcpmuxWebEndpoint {
        guard let webURL, let endpoint = AcpmuxWebEndpoint(webURL: webURL) else {
            throw AcpmuxStatusClient.Failure.noWebSocket
        }
        return endpoint
    }
}
