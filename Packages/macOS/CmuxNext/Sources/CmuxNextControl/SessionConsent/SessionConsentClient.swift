import CmuxNextCompat
import CmuxNextSettings
public import Darwin
public import Foundation

/// Asks a running cmux NIGHTLY, over its control socket, for a NEW session of this build's own
/// (`auth.session.request`, answered by ``SessionConsentResponder`` after the person says yes there).
/// NIGHTLY's own session never crosses the socket.
///
/// The client checks the server before it sends anything: the process listening on the socket must be
/// this user's and signed by cmux's team as NIGHTLY. Any failure (no NIGHTLY, a refusal, a deny, a timeout,
/// a malformed answer) is nil and the caller carries on signed out. Nothing here logs or keeps the tokens.
///
/// ```swift
/// let client = SessionConsentClient(socketPath: SessionConsentClient.nightlySocketPath(), timeout: .seconds(150))
/// let tokens = await client.requestTokens(bundleID: id, tag: tag, stackProjectID: project, apiOrigin: origin)
/// ```
public struct SessionConsentClient: Sendable {
    /// cmux's Apple Developer team.
    public static let teamIdentifier = "7WLXT3NR37"
    /// cmux NIGHTLY, the only build that answers `auth.session.request`.
    public static let nightlyBundleID = "com.cmuxterm.app.nightly"

    /// NIGHTLY's control socket.
    public let socketPath: String
    /// The bound on each send and receive; it covers the person's answer (Rust's `CLIENT_TIMEOUT`, 150 s).
    public let timeout: Duration
    /// The user the server must run as (this process's own).
    public let uid: uid_t
    /// Reads the server's signature.
    public let signers: any SessionConsentSignerReading

    /// Longest answer read; a pair is a few kilobytes.
    static let maxResponseBytes = 64 << 10

    /// - Parameters:
    ///   - socketPath: NIGHTLY's control socket path.
    ///   - timeout: Bounds each send and receive.
    ///   - uid: The user the server must run as. Defaults to this process's.
    ///   - signers: The signature read. Defaults to the Security framework's.
    public init(socketPath: String, timeout: Duration, uid: uid_t = getuid(),
                signers: any SessionConsentSignerReading = SessionConsentCodeCheck()) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.uid = uid
        self.signers = signers
    }

    /// The control socket a running cmux NIGHTLY listens on: the name its ``LaunchIdentity`` gives it
    /// (``BuildIdentity/controlSocket(userHome:)``, moved into the state folder).
    public static func nightlySocketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let paths = ControlSocketPath.shared
        guard let named = BuildIdentity(bundleID: nightlyBundleID, bundledTag: nil).controlSocket(userHome: home) else {
            return paths.resolve(bundleID: nightlyBundleID, tag: nil, isDebugBuild: false, home: home)
        }
        return paths.moved(named, home: home).path
    }

    /// Whether `peer`, the process listening on the socket, is this user's NIGHTLY signed by cmux's team.
    func admitsServer(_ peer: SessionConsentPeer?) -> Bool {
        guard let peer, peer.uid == uid, let signer = signers.signer(of: peer.auditToken) else { return false }
        return signer.identifier == Self.nightlyBundleID && signer.teamID == Self.teamIdentifier
    }

    /// A NEW session for this build, minted by NIGHTLY after the person says yes there, as plain tokens; nil
    /// for no NIGHTLY, a refusal, a deny, a timeout or anything malformed.
    public func requestTokens(bundleID: String, tag: String?, stackProjectID: String,
                              apiOrigin: String) async -> (accessToken: String?, refreshToken: String)? {
        struct Params: Encodable { var bundleId: String, tag: String?, stackProjectId: String, apiOrigin: String }
        struct Request: Encodable { var id = 1, method = SessionConsentResponder.method, params: Params }
        let params = Params(bundleId: bundleID, tag: tag, stackProjectId: stackProjectID, apiOrigin: apiOrigin)
        guard let line = try? JSONEncoder().encode(Request(params: params)) else { return nil }
        let client = self
        return await withCheckedContinuation { continuation in
            // concurrency-allow: one bounded exchange of blocking socket calls (SO_SNDTIMEO/SO_RCVTIMEO cap each
            // at `timeout`) runs on a global utility queue, never the caller's executor or the main thread.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: client.exchange(request: line + Data([0x0A])))
            }
        }
    }

    /// Connects, checks the server, sends `request` (one line) and reads one answer line. Blocking.
    func exchange(request: Data) -> (accessToken: String?, refreshToken: String)? {
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
        guard admitsServer(SessionConsentPeer(connection: descriptor)) else { return nil }
        guard send(descriptor, request) else { return nil }
        guard let line = readLine(descriptor) else { return nil }
        return Self.tokens(fromResponse: line)
    }

    /// The tokens in a response line, or nil for an error, a refusal or anything malformed.
    static func tokens(fromResponse line: Data) -> (accessToken: String?, refreshToken: String)? {
        guard let response = try? JSONValue.parse(line).objectValue, response["ok"]?.boolValue == true,
              let result = response["result"]?.objectValue,
              let refresh = result["refresh_token"]?.stringValue, !refresh.isEmpty else { return nil }
        return (accessToken: result["access_token"]?.stringValue, refreshToken: refresh)
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
