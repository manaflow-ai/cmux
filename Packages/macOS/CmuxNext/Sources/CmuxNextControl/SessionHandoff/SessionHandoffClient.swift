import CmuxNextCompat
import CmuxNextSettings
import Darwin
public import Foundation

/// Asks a running cmux NIGHTLY for its signed-in Stack session over NIGHTLY's control socket
/// (`auth.session.handoff`, answered by ``SessionHandoffResponder``).
///
/// The client checks the server before it sends anything: the process listening on the socket must be
/// this user's and signed by cmux's team as NIGHTLY (``SessionHandoffPolicy/admitsServer(_:)``). Any
/// failure (no NIGHTLY, a refusal, a timeout, a malformed answer) is nil and the caller carries on
/// without a session. Nothing here logs or keeps the pair.
///
/// ```swift
/// let nightly = SessionHandoffClient(socketPath: SessionHandoffClient.nightlySocketPath(), policy: SessionHandoffPolicy())
/// let pair = await nightly.fetch()
/// ```
public struct SessionHandoffClient: Sendable {
    /// NIGHTLY's control socket.
    public let socketPath: String
    /// The server check.
    public let policy: SessionHandoffPolicy
    /// The bound on each send and receive.
    public let timeout: Duration

    /// Longest answer read; a pair is a few kilobytes.
    static let maxResponseBytes = 64 << 10

    /// - Parameters:
    ///   - socketPath: NIGHTLY's control socket path.
    ///   - policy: Checks the server.
    ///   - timeout: Bounds each send and receive (default 2 s).
    public init(socketPath: String, policy: SessionHandoffPolicy, timeout: Duration = .seconds(2)) {
        self.socketPath = socketPath
        self.policy = policy
        self.timeout = timeout
    }

    /// The control socket a running cmux NIGHTLY listens on: the name its ``LaunchIdentity`` gives it
    /// (``BuildIdentity/controlSocket(userHome:)``, moved into the state folder).
    public static func nightlySocketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let paths = ControlSocketPath.shared
        guard let named = BuildIdentity(bundleID: SessionHandoffPolicy.serverBundleID, bundledTag: nil).controlSocket(userHome: home) else {
            return paths.resolve(bundleID: SessionHandoffPolicy.serverBundleID, tag: nil, isDebugBuild: false, home: home)
        }
        return paths.moved(named, home: home).path
    }

    /// The client for this user's cmux NIGHTLY, checked by the Security framework.
    public static func nightly() -> SessionHandoffClient {
        SessionHandoffClient(socketPath: nightlySocketPath(), policy: SessionHandoffPolicy())
    }

    /// Whether NIGHTLY listens on ``socketPath`` now: one non-blocking `connect` and the server check
    /// (``SessionHandoffPolicy/admitsServer(_:)``), no request.
    public func isListening() -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return connect(descriptor, to: socketPath) && policy.admitsServer(SessionHandoffPeer(connection: descriptor))
    }

    /// NIGHTLY's session as plain tokens (for `CloudAuth`, which does not know this type), or nil.
    public func fetchTokens() async -> (accessToken: String?, refreshToken: String)? {
        await fetch().map { (accessToken: $0.accessToken, refreshToken: $0.refreshToken) }
    }

    /// NIGHTLY's session, or nil.
    public func fetch() async -> SessionHandoffPair? {
        let client = self
        return await withCheckedContinuation { continuation in
            // concurrency-allow: one bounded exchange of blocking socket calls (SO_SNDTIMEO/SO_RCVTIMEO cap each
            // at `timeout`) runs on a global utility queue, never the caller's executor or the main thread.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: client.exchange())
            }
        }
    }

    /// Connects, checks the server, sends the request and reads one answer line. Blocking.
    func exchange() -> SessionHandoffPair? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let (seconds, attoseconds) = timeout.components
        var bound = timeval(tv_sec: Int(clamping: seconds), tv_usec: Int32(clamping: attoseconds / 1_000_000_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))
        guard connect(descriptor, to: socketPath) else { return nil }
        guard policy.admitsServer(SessionHandoffPeer(connection: descriptor)) else { return nil }
        let request = Data(#"{"id":1,"method":"\#(SessionHandoffPolicy.method)","params":{}}"#.utf8) + Data([0x0A])
        guard send(descriptor, request) else { return nil }
        guard let line = readLine(descriptor) else { return nil }
        return Self.pair(fromResponse: line)
    }

    /// The pair in a response line, or nil for an error, a refusal or anything malformed.
    static func pair(fromResponse line: Data) -> SessionHandoffPair? {
        guard let response = try? JSONValue.parse(line).objectValue, response["ok"]?.boolValue == true,
              let result = response["result"]?.objectValue else { return nil }
        return SessionHandoffPair(accessToken: result["access_token"]?.stringValue, refreshToken: result["refresh_token"]?.stringValue)
    }

    private func connect(_ descriptor: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count > 1, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) == 0 }
        }
    }

    private func send(_ descriptor: Int32, _ bytes: Data) -> Bool {
        var remaining = bytes
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                remaining = remaining.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Bytes up to the first newline, or nil on EOF, timeout or an oversized answer.
    private func readLine(_ descriptor: Int32) -> Data? {
        var received = Data()
        var chunk = Data(count: 4096)
        while received.count <= Self.maxResponseBytes {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                received.append(chunk.prefix(count))
                if let newline = received.firstIndex(of: 0x0A) { return Data(received.prefix(upTo: newline)) }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }
}
