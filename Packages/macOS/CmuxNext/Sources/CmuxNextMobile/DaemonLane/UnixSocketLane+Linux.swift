#if !canImport(Network)
import CmuxNextDaemon
import Dispatch
public import Foundation
import Glibc
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A `MobileByteLane` over a Unix stream socket where there is no Network.framework (Linux), with the
/// surface of the macOS lane. The socket is non-blocking: a read or write that would block waits for
/// readiness on a libdispatch source (epoll), so no thread ever blocks on the daemon. Chromium's
/// `SocketPosix` waits on its descriptor watcher the same way (net/socket/socket_posix.cc,
/// base/message_loop/message_pump_epoll.cc).
public actor UnixSocketLane: MobileByteLane {
    public enum Failure: Error, Equatable, Sendable {
        case connectTimedOut(path: String)
        case connectFailed(path: String, detail: String)
    }

    private enum Readiness {
        case readable, writable
    }

    private let socket: LaneDescriptor
    private let queue = DispatchQueue(label: "cmux.next.mobile.unix-lane", qos: .userInitiated)
    /// The readiness waits in flight, by id: ``close()`` cancels them, which wakes their callers.
    private var waits: [UInt64: any DispatchSourceProtocol] = [:]
    private var lastWait: UInt64 = 0

    private init(socket: LaneDescriptor) {
        self.socket = socket
    }

    /// Connects to `path`. A Unix stream connect on Linux ends in the call (`unix_stream_connect`: a
    /// non-blocking socket whose listener's queue is full gets EAGAIN, never EINPROGRESS), so the wedged
    /// daemon that `deadline` bounds on macOS is a typed failure here at once.
    public static func connect(path: String, deadline: Duration = .seconds(2)) async throws -> UnixSocketLane {
        guard let address = UnixSocketAddress(path: path) else {
            throw Failure.connectFailed(path: path, detail: "the path does not fit sun_path")
        }
        let flags = SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue
        let fd = Glibc.socket(AF_UNIX, Int32(truncatingIfNeeded: flags), 0)
        guard fd >= 0 else { throw Failure.connectFailed(path: path, detail: describe(errno)) }
        guard address.connect(fd) == 0 else {
            let code = errno
            _ = Glibc.close(fd)
            throw Failure.connectFailed(path: path, detail: describe(code))
        }
        return UnixSocketLane(socket: LaneDescriptor(fd))
    }

    public func read(maximumBytes: Int) async throws -> Data? {
        var buffer = Data(count: max(1, maximumBytes))
        let fd = socket.fd
        let receive = {
            // SAFETY: read writes at most buffer.count bytes into the Data's own storage, which the closure
            // lends for the call and nothing else touches meanwhile.
            unsafe buffer.withUnsafeMutableBytes { unsafe Glibc.read(fd, $0.baseAddress, $0.count) }
        }
        var outcome = try Self.transfer(receive)
        while case .wouldBlock = outcome {
            await wait(until: .readable)
            outcome = try Self.transfer(receive)
        }
        // No bytes: the stream ended, or close() shut the socket down.
        guard case .moved(let count) = outcome, count > 0 else { return nil }
        buffer.count = count
        return buffer
    }

    public func write(_ data: Data) async throws {
        var offset = 0
        let fd = socket.fd
        while offset < data.count {
            let outcome = try Self.transfer {
                // SAFETY: send reads the bytes from `offset` to the end of the Data's own storage, which the
                // closure lends for the call; offset < bytes.count, so the start and the length stay inside it.
                unsafe data.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    // No SIGPIPE on a send after the daemon went away: the send fails with EPIPE.
                    return unsafe Glibc.send(fd, base + offset, bytes.count - offset,
                                             Int32(truncatingIfNeeded: MSG_NOSIGNAL))
                }
            }
            switch outcome {
            case .moved(let sent): offset += sent
            case .wouldBlock: await wait(until: .writable)
            }
        }
    }

    /// Shuts the socket down both ways and wakes every waiting read and write: a read then sees the end of
    /// the stream and a write fails with EPIPE. Idempotent.
    public func close() async {
        _ = Glibc.shutdown(socket.fd, Int32(truncatingIfNeeded: SHUT_RDWR))
        for source in waits.values {
            source.cancel()
        }
    }

    /// Returns once the socket is `readiness`, or ``close()`` cancelled the wait; the caller tries its call
    /// again either way. The source cancels itself on its first event, and only its cancel handler resumes,
    /// so the wait resumes once, whichever comes first.
    private func wait(until readiness: Readiness) async {
        let source: any DispatchSourceProtocol = switch readiness {
        case .readable: DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
        case .writable: DispatchSource.makeWriteSource(fileDescriptor: socket.fd, queue: queue)
        }
        lastWait &+= 1
        let id = lastWait
        waits[id] = source
        let socket = socket
        _ = try? await withOnceContinuation { (ready: OnceContinuation<Void, OnceContinuationError>) in
            source.setEventHandler { source.cancel() }
            source.setCancelHandler {
                // The descriptor stays open until libdispatch has stopped watching it.
                withExtendedLifetime(socket) {}
                ready.resume(returning: ())
            }
            source.activate()
        }
        waits[id] = nil
    }

    /// What one non-blocking read or send did: moved that many bytes (0 from a read: the end of the stream),
    /// or would have blocked.
    private enum Transfer {
        case moved(Int)
        case wouldBlock
    }

    /// Runs `call`, a read or send that returns a byte count or -1 with `errno` set, again after an EINTR.
    /// - Throws: the errno of any other failure than EAGAIN.
    private static func transfer(_ call: () -> Int) throws(POSIXError) -> Transfer {
        var result = call()
        while result < 0, errno == EINTR {
            result = call()
        }
        if result >= 0 { return .moved(result) }
        let code = errno
        guard code == EAGAIN || code == EWOULDBLOCK else { throw error(code) }
        return .wouldBlock
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func describe(_ code: Int32) -> String {
        "\(error(code).code)"
    }
}

/// The lane's socket, closed when its last holder lets go: the lane and the cancel handler of each readiness
/// source on it. libdispatch must stop watching a descriptor before it is closed, or its late unregister would
/// hit whatever reused the number (dispatch_source_cancel(3)).
private final class LaneDescriptor: Sendable {
    let fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    deinit {
        _ = Glibc.close(fd)
    }
}
#endif
