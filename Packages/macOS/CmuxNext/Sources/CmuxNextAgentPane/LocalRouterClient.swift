import CmuxNextCompat
public import Foundation
import Network

/// The local model relay's admin socket (cmux-tui crate cmux-coderouter,
/// ``socketPath(acpmuxHome:uid:)``, 0600): one JSON object per line,
/// `{"op": ...}`, one reply line each. The app uses it to hand the relay the
/// signed-in account's bearer for the hosted cmux model router
/// (`set_upstream`) and to take it back (`clear_upstream`). The bearer goes
/// only to the relay; agents get the relay's own per-session keys.
public nonisolated struct LocalRouterClient: Sendable {
    public enum Failure: Error, Equatable {
        case refused(String)
        case closed
        /// The socket path does not fit a Unix socket address (`sun_path`).
        case socketPathTooLong(String)
        /// The short socket folder is not a folder that only this user owns and can enter.
        case untrustedSocketFolder(String)
    }

    /// The admin socket of the relay that the daemon in the acpmux home starts.
    public let socketPath: String

    public init(acpmuxHome home: URL) {
        socketPath = Self.socketPath(acpmuxHome: home)
    }

    /// The relay's admin socket for the acpmux home `home`, by the rule the relay
    /// (cmux-coderouter `admin_socket_path`) and acpmux share:
    /// `<home>/router/router.sock` when it fits a Unix socket address
    /// (``AcpmuxEnvironment/maxSocketPathBytes``), else
    /// `/tmp/acpmux-<uid>/<fnv1a64(home)>-router.sock`, the private per-user
    /// folder of the daemon socket's short alias (cx-8iw6m: a long home made a
    /// path that the Network framework traps on).
    public static func socketPath(acpmuxHome home: URL, uid: UInt32 = getuid()) -> String {
        let preferred = home.appendingPathComponent("router", isDirectory: true).appendingPathComponent("router.sock").path
        if preferred.utf8.count <= AcpmuxEnvironment.maxSocketPathBytes { return preferred }
        return "\(shortFolder(uid: uid))/\(String(format: "%016llx", AcpmuxEnvironment.fnv1a64(home.path)))-router.sock"
    }

    static func shortFolder(uid: UInt32) -> String { "/tmp/acpmux-\(uid)" }

    /// The endpoint for `path`, or a ``Failure`` where a connection must not be
    /// tried: a path past the Unix socket limit (`NWEndpoint.unix` traps on one)
    /// or a short-folder path whose folder another user could control (the
    /// bearer goes over this socket).
    static func endpoint(_ path: String, uid: UInt32 = getuid()) throws -> NWEndpoint {
        guard path.utf8.count <= AcpmuxEnvironment.maxSocketPathBytes else { throw Failure.socketPathTooLong(path) }
        let folder = shortFolder(uid: uid)
        if (path as NSString).deletingLastPathComponent == folder {
            var info = stat()
            // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat
            // into `info`, a local.
            guard unsafe blockingLstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid, info.st_mode & 0o077 == 0 else {
                throw Failure.untrustedSocketFolder(folder)
            }
        }
        return .unix(path: path)
    }

    /// Hands the relay the hosted router's origin and a bearer valid until
    /// `expiresAt` (Unix seconds). Throws when no relay answers or it refuses.
    /// Returns the relay's process id (nil from a relay too old to name it).
    @discardableResult
    @concurrent public func setUpstream(origin: String, bearer: String, expiresAt: UInt64, deadline: Duration = .seconds(3)) async throws -> Int? {
        let line = try JSONSerialization.data(withJSONObject: [
            "op": "set_upstream", "origin": origin, "bearer": bearer, "expires_at": NSNumber(value: expiresAt),
        ] as [String: Any])
        let reply = try await Self.exchange(socketPath: socketPath, line: line, deadline: deadline)
        return (reply.value["pid"] as? NSNumber)?.intValue
    }

    /// Returns true when the relay process `pid` is gone: at once when the
    /// relay that answers now is another process (it replaced `pid` before
    /// the watch began), else when the admin connection reads end-of-file,
    /// which happens only when the relay exits (a new relay holds no
    /// bearer). Returns false at once when no relay answers.
    @concurrent public func waitUntilGone(pid: Int?) async -> Bool {
        guard let endpoint = try? Self.endpoint(socketPath) else { return false }
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        return await withTaskCancellationHandler {
            // Cancelled before the start: a cancelled connection may never report a state.
            guard !Task.isCancelled else { return false }
            do {
                try await AcpmuxStatusClient.start(connection)
                try await AcpmuxStatusClient.send(Data(#"{"op":"status"}"#.utf8) + Data([0x0A]), on: connection)
            } catch {
                return false
            }
            var buffer = Data()
            var checked = false
            while true {  // wakeup-allow: each pass awaits socket data; EOF, an error or cancellation ends it
                guard let chunk = try? await AcpmuxStatusClient.receive(on: connection) else { return true }
                guard !checked else { continue }
                buffer += chunk
                guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
                checked = true
                let status = (try? JSONSerialization.blockingJSONObject(with: buffer[buffer.startIndex..<newline])) as? [String: Any]
                let now = (status?["pid"] as? NSNumber)?.intValue
                if let pid, let now, now != pid { return true }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Takes the bearer back (sign-out): the relay then answers 503 until a new one.
    @concurrent public func clearUpstream(deadline: Duration = .seconds(3)) async throws {
        let line = try JSONSerialization.data(withJSONObject: ["op": "clear_upstream"])
        _ = try await Self.exchange(socketPath: socketPath, line: line, deadline: deadline)
    }

    private static func exchange(socketPath: String, line: Data, deadline: Duration) async throws -> ResultBox {
        let target = try endpoint(socketPath)
        let connection = NWConnection(to: target, using: .tcp)
        defer { connection.cancel() }
        return try await withAgentPaneDeadline(deadline, label: "local router", onTimeout: { connection.cancel() }) {
            try await AcpmuxStatusClient.start(connection)
            try await AcpmuxStatusClient.send(line + Data([0x0A]), on: connection)
            var buffer = Data()
            while true {  // wakeup-allow: bounded each pass awaits socket data; EOF, an error or the call's deadline ends it
                guard let chunk = try await AcpmuxStatusClient.receive(on: connection) else { throw Failure.closed }
                buffer += chunk
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let object = (try? JSONSerialization.blockingJSONObject(with: buffer[buffer.startIndex..<newline])) as? [String: Any] ?? [:]
                    if let error = object["error"] as? String { throw Failure.refused(error) }
                    return ResultBox(object)
                }
                if buffer.count > 1 << 16 { throw Failure.closed }
            }
        }
    }
}
