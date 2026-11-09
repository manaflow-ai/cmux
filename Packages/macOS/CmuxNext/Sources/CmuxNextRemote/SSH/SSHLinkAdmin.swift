import Darwin
public import Foundation

/// A running link's own state, as `cmux-tui remote connect` answers it on `PATH.admin`
/// (cmux-remote `admin/link.rs`): the link is the only layer that redials (cmuxterm-hq#7766),
/// so the app reads where it is instead of inferring it.
public struct SSHLinkState: Equatable, Sendable {
    /// `connecting` (a first dial in flight), `connected`, `reconnecting`, `disconnected`
    /// (parked between dials), `down` (an `await-ready` ran out of time), `failed` (a permanent
    /// error: the link exits) or `closed`.
    public let state: String
    /// Why the link is not connected, when it is not.
    public let reason: String?

    public init(state: String, reason: String?) {
        self.state = state
        self.reason = reason
    }

    /// The link redials and its last dial failed: the reason to show while it keeps trying.
    public var redialReason: String? {
        switch state {
        case "connecting", "reconnecting", "disconnected", "down": reason.flatMap { $0.isEmpty ? nil : $0 }
        default: nil
        }
    }

    /// Decodes one answer line (`{"ok":true,"result":{"state":…,"reason":…}}`); nil for anything else.
    public static func decode(_ line: Data) -> SSHLinkState? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["ok"] as? Bool == true,
              let result = object["result"] as? [String: Any], let state = result["state"] as? String else { return nil }
        return SSHLinkState(state: state, reason: result["reason"] as? String)
    }
}

/// A link's admin socket and the two requests it answers. Each opens one connection, writes one
/// line and reads one line, on a dispatch thread (never the caller's executor): `await-ready`
/// blocks there until the link is connected or its deadline passes.
public struct SSHLinkAdmin: Sendable {
    /// `PATH.admin` beside the link's local socket (`link_admin_socket`).
    public let path: String
    /// Tests only: runs on the request's dispatch thread after each exchange (its line and whether
    /// the link answered), before the caller resumes, so a test can order what the link does
    /// between a request's failure and its caller seeing it.
    let exchanged: (@Sendable (String, Bool) -> Void)?

    public init(localSocket: String) {
        self.init(localSocket: localSocket, exchanged: nil)
    }

    init(localSocket: String, exchanged: (@Sendable (String, Bool) -> Void)?) {
        path = localSocket + ".admin"
        self.exchanged = exchanged
    }

    /// The link's state now; nil when its socket does not answer.
    public func linkState() async -> SSHLinkState? {
        await request(line: #"{"method":"link-state"}"#, timeout: .seconds(5))
    }

    /// Waits until the link is connected or `deadline` passes; a parked dial dials at once. The
    /// deadline is the caller's (a person's open or Reconnect); the link caps it at 120 s.
    public func awaitReady(within deadline: Duration) async -> SSHLinkState? {
        // Rounded up: what is left of a person's 3 s is still 3000 ms, never 2999.
        let (seconds, attoseconds) = deadline.components
        let milliseconds = max(0, seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
        return await request(line: #"{"method":"await-ready","within_ms":\#(milliseconds)}"#, timeout: deadline + .seconds(5))
    }

    private func request(line: String, timeout: Duration) async -> SSHLinkState? {
        let path = path, exchanged = exchanged
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let state = Self.exchange(path, line: line, timeout: timeout)
                exchanged?(line, state != nil)
                continuation.resume(returning: state)
            }
        }
    }

    /// One blocking exchange; runs only on a dispatch thread (``request(line:timeout:)``).
    private static func exchange(_ path: String, line: String, timeout: Duration) -> SSHLinkState? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: Int(timeout.components.seconds), tv_usec: Int32(timeout.components.attoseconds / 1_000_000_000_000))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: a dispatch thread (request), never the main actor; a local Unix socket connect.
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            // concurrency-allow: a dispatch thread (request), never the main actor.
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return nil }
            offset += written
        }
        var answer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while answer.count < 1 << 16 {
            // concurrency-allow: a dispatch thread (request), never the main actor; bounded by SO_RCVTIMEO.
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            answer.append(contentsOf: chunk[..<count])
            if let newline = answer.firstIndex(of: 0x0A) { return SSHLinkState.decode(answer[..<newline]) }
        }
        return answer.isEmpty ? nil : SSHLinkState.decode(answer)
    }
}
