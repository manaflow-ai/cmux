public import Foundation
import Network

/// The local model relay's admin socket (cmux-tui crate cmux-coderouter,
/// `<acpmux home>/router/router.sock`, 0600): one JSON object per line,
/// `{"op": ...}`, one reply line each. The app uses it to hand the relay the
/// signed-in account's bearer for the hosted cmux model router
/// (`set_upstream`) and to take it back (`clear_upstream`). The bearer goes
/// only to the relay; agents get the relay's own per-session keys.
public nonisolated struct LocalRouterClient: Sendable {
    public enum Failure: Error, Equatable {
        case refused(String)
        case closed
    }

    /// The admin socket of the relay that the daemon in the acpmux home starts.
    public let socketPath: String

    public init(acpmuxHome home: URL) {
        socketPath = home.appendingPathComponent("router", isDirectory: true).appendingPathComponent("router.sock").path
    }

    /// Hands the relay the hosted router's origin and a bearer valid until
    /// `expiresAt` (Unix seconds). Throws when no relay answers or it refuses.
    @concurrent public func setUpstream(origin: String, bearer: String, expiresAt: UInt64, deadline: Duration = .seconds(3)) async throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "op": "set_upstream", "origin": origin, "bearer": bearer, "expires_at": NSNumber(value: expiresAt),
        ] as [String: Any])
        _ = try await Self.exchange(socketPath: socketPath, line: line, deadline: deadline)
    }

    /// Takes the bearer back (sign-out): the relay then answers 503 until a new one.
    @concurrent public func clearUpstream(deadline: Duration = .seconds(3)) async throws {
        let line = try JSONSerialization.data(withJSONObject: ["op": "clear_upstream"])
        _ = try await Self.exchange(socketPath: socketPath, line: line, deadline: deadline)
    }

    private static func exchange(socketPath: String, line: Data, deadline: Duration) async throws -> ResultBox {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        return try await withAgentPaneDeadline(deadline, label: "local router", onTimeout: { connection.cancel() }) {
            try await AcpmuxStatusClient.start(connection)
            try await AcpmuxStatusClient.send(line + Data([0x0A]), on: connection)
            var buffer = Data()
            while true {  // wakeup-allow: each pass awaits socket data; EOF, error or the deadline ends it
                guard let chunk = try await AcpmuxStatusClient.receive(on: connection) else { throw Failure.closed }
                buffer += chunk
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let object = (try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<newline])) as? [String: Any] ?? [:]
                    if let error = object["error"] as? String { throw Failure.refused(error) }
                    return ResultBox(object)
                }
                if buffer.count > 1 << 16 { throw Failure.closed }
            }
        }
    }
}
