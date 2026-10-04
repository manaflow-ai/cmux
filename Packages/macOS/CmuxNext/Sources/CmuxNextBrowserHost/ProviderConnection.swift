public import Foundation
import Darwin
import Synchronization

public nonisolated enum ProviderConnectionError: Error, Hashable, Sendable {
    case socket(errno: Int32)
    case pathTooLong(String)
    case connect(path: String, errno: Int32)
    /// The listener belongs to another user: the secret is never sent to it.
    case foreignPeer(uid: uid_t)
}

/// One provider connection to the browser host over a Unix stream socket.
/// A dedicated reader thread blocks in `read` and delivers whole frames, in
/// order, through `frames` (bounded: a reader that falls 1024 frames behind
/// closes the link rather than buffer without limit). Writes go through one
/// serial queue, so frames reach the socket in `send` order. `close` shuts
/// the socket down, which ends the reader; the descriptor is closed after
/// the last queued write. Nothing polls.
public nonisolated final class ProviderConnection: Sendable {
    private struct State {
        var closed: String?
        var started = false
        var fdOpen = true
    }

    public let frames: AsyncStream<ProviderFrame>
    private let continuation: AsyncStream<ProviderFrame>.Continuation
    private let fd: Int32
    private let state = Mutex(State())
    private let writes = DispatchQueue(label: "com.cmuxterm.next.browser-host.provider.write")

    /// Takes ownership of a connected stream socket.
    public init(fd: Int32, frameBufferLimit: Int = 1024) {
        self.fd = fd
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        (frames, continuation) = AsyncStream.makeStream(of: ProviderFrame.self, bufferingPolicy: .bufferingOldest(frameBufferLimit))
    }

    /// The reader thread and queued writes hold the connection, so neither
    /// runs here: close the descriptor directly.
    deinit {
        let open = state.withLock { state -> Bool in
            defer { state.fdOpen = false }
            return state.fdOpen
        }
        if open { Darwin.close(fd) }
        continuation.finish()
    }

    /// Connects to the host's provider socket, off the main actor, and
    /// checks that the listener runs as this user.
    @concurrent
    public static func dial(path: String) async throws(ProviderConnectionError) -> ProviderConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socket(errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw .pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .connect(path: path, errno: code)
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(fd)
            throw .foreignPeer(uid: uid)
        }
        return ProviderConnection(fd: fd)
    }

    /// The pid of the process at the other end (`LOCAL_PEERPID`), nil when
    /// the socket cannot tell.
    public var peerPID: pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    /// Why the connection ended, nil while it is open.
    public var closeReason: String? { state.withLock { $0.closed } }

    /// Starts the reader thread. Call once.
    public func start() {
        let run = state.withLock { state -> Bool in
            guard !state.started, state.closed == nil else { return false }
            state.started = true
            return true
        }
        guard run else { return }
        let thread = Thread { [self] in readLoop() }
        thread.name = "cmux browser-host provider reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Queues one frame. Throws when it cannot be encoded (too large);
    /// returns false once the connection is closed.
    @discardableResult
    public func send(_ frame: ProviderFrame) throws(ProviderCodecError) -> Bool {
        guard state.withLock({ $0.closed == nil }) else { return false }
        return sendEncoded(try ProviderCodec.encode(frame))
    }

    /// Queues bytes that already carry their length prefix.
    @discardableResult
    func sendEncoded(_ bytes: Data) -> Bool {
        guard state.withLock({ $0.closed == nil }) else { return false }
        writes.async { [self] in write(bytes) }
        return true
    }

    /// Closes the connection; the reader ends and `frames` finishes.
    public func close(reason: String = "closed by the app") {
        let unstarted = state.withLock { state -> Bool? in
            guard state.closed == nil else { return nil }
            state.closed = reason
            return !state.started
        }
        guard let unstarted else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        // A started reader finishes the stream and closes the descriptor.
        if unstarted { finish() }
    }

    private func write(_ bytes: Data) {
        guard state.withLock({ $0.fdOpen && $0.closed == nil }) else { return }
        let failure: Int32? = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return written < 0 ? errno : EPIPE
                }
            }
            return nil
        }
        if let failure { close(reason: "provider write failed (errno \(failure))") }
    }

    private func readLoop() {
        var decoder = ProviderFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var reason = "the browser host closed the connection"
        var open = true
        while open {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBytes { decoder.push(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                do {
                    while open, let frame = try decoder.next() {
                        if case .dropped = continuation.yield(frame) {
                            reason = "the app fell behind the browser host"
                            open = false
                        }
                    }
                } catch {
                    reason = "bad provider frame: \(error)"
                    open = false
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count < 0 { reason = "provider read failed (errno \(errno))" }
                open = false
            }
        }
        state.withLock { if $0.closed == nil { $0.closed = reason } }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        finish()
    }

    /// Ends the stream and closes the descriptor after queued writes.
    private func finish() {
        continuation.finish()
        writes.async { [self] in
            let close = state.withLock { state -> Bool in
                defer { state.fdOpen = false }
                return state.fdOpen
            }
            if close { Darwin.close(fd) }
        }
    }
}
