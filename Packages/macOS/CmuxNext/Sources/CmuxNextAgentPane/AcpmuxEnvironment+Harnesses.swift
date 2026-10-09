import Foundation
import Network

/// A refusal from the acpmux daemon with its JSON-RPC code and, when the daemon names one, its
/// reason id from `data.reason` (`harness.exists`, `harness.not_removable`, `harness.secret_inline`,
/// `harness.not_found`).
public nonisolated struct AcpmuxRPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int?
    public var name: String?
    public var message: String

    public init(code: Int? = nil, name: String? = nil, message: String) {
        self.code = code
        self.name = name
        self.message = message
    }

    init(_ error: [String: Any]) {
        let data = error["data"] as? [String: Any]
        code = (error["code"] as? NSNumber)?.intValue
        name = data?["reason"] as? String ?? data?["code"] as? String
        message = error["message"] as? String ?? "acpmux request failed"
    }

    /// The daemon does not serve the method (an older acpmux): callers fall back to the CLI.
    public var isMethodMissing: Bool { code == -32601 }
    public var errorDescription: String? { message }
}

/// The harness operations of BRING-YOUR-OWN-HARNESS (H1, H2) on the local daemon's unix socket:
/// list, add, remove (with a restorable backup), restore, doctor and the ACP Registry. Each
/// answers the result object as JSON bytes, so callers in other modules parse it with their own
/// JSON type.
public nonisolated enum AcpmuxHarnessMethod: String, Sendable, CaseIterable {
    case list = "_acpmux/harnesses"
    case add = "_acpmux/harness/add"
    case remove = "_acpmux/harness/remove"
    case restore = "_acpmux/harness/restore"
    case doctor = "_acpmux/harness/doctor"
    case registry = "_acpmux/registry"

    /// Doctor starts the harness and sends one prompt; a registry refresh fetches over HTTPS.
    var deadline: Duration {
        switch self {
        case .doctor: .seconds(150)
        case .registry: .seconds(40)
        case .list, .add, .remove, .restore: .seconds(10)
        }
    }
}

extension AcpmuxEnvironment {
    /// One harness operation. Throws ``AcpmuxRPCError`` for a daemon refusal (an older daemon
    /// answers `isMethodMissing`) and `AcpmuxStatusClient.Failure.unreachable` when no daemon runs.
    public nonisolated func harness(_ method: AcpmuxHarnessMethod, params: [String: any Sendable] = [:]) async throws -> Data {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: method.rawValue, params: params,
                                                       deadline: method.deadline, detailed: true)
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Calls `onChange` for each `_acpmux/harnesses_changed` the daemon sends (a profile file
    /// written, removed or reloaded), until the task is cancelled or the daemon closes the
    /// connection. Event-driven: one `_acpmux/watch` connection, no polling.
    public nonisolated func watchHarnesses(_ onChange: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let socketPath = socketPath
        return Task.detached {
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            defer { connection.cancel() }
            await withTaskCancellationHandler {
                try? await Self.readHarnessChanges(on: connection, onChange: onChange)
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private nonisolated static func readHarnessChanges(on connection: NWConnection,
                                                      onChange: @escaping @Sendable () -> Void) async throws {
        try await AcpmuxStatusClient.start(connection)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-harness-settings", "version": "1"],
                       "clientCapabilities": [:]],
        ]
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += try JSONSerialization.data(withJSONObject: request)
            payload.append(0x0A)
        }
        try await AcpmuxStatusClient.send(payload, on: connection)
        var buffer = Data()
        // wakeup-allow: each pass awaits socket data; EOF, an error or cancellation ends it
        while !Task.isCancelled {
            guard let chunk = try await AcpmuxStatusClient.receive(on: connection) else { return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if Self.isHarnessChange(line) { onChange() }
            }
            // A session event larger than this is not one this reader needs whole.
            if buffer.count > 4 << 20 { buffer.removeAll(keepingCapacity: true) }
        }
    }

    /// Whether `line` is a `_acpmux/harnesses_changed` notification.
    nonisolated static func isHarnessChange(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["method"] as? String == "_acpmux/harnesses_changed"
    }
}
