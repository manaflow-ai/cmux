import Darwin
import Dispatch
public import Foundation
import OSLog

// Same subsystem as the read-side helper, with a sibling category so broken-pipe
// write diagnostics can be queried independently of reads.
nonisolated private let processPipeWriterLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ProcessPipeWriter"
)

// Upper bound on how long `waitForWritable` waits for a non-blocking descriptor
// to drain. Blocking descriptors never reach that path, so this only bounds the
// misuse/edge case; it must stay finite so the calling thread can never park
// forever.
private let processPipeWritableWaitTimeoutMilliseconds: UInt64 = 5_000

/// The result of a best-effort write to a process pipe or socket descriptor.
public enum ProcessPipeWriteOutcome: Equatable, Sendable {
    /// Every byte was written.
    case completed
    /// The peer closed the descriptor mid-write (`EPIPE`/`ECONNRESET`); the
    /// remaining bytes were dropped. This is an expected lifecycle race when a
    /// child exits early or a reader disconnects, not an actionable error.
    case brokenPipe
    /// The write failed for another reason; carries the captured `errno`.
    case failed(errnoCode: Int32)
}

extension FileHandle {
    /// Writes `data` with POSIX `write(2)`, returning instead of raising an
    /// Objective-C `NSException` when the peer has gone away.
    ///
    /// Foundation's `FileHandle.write(_:)` raises `NSFileHandleOperationException`
    /// — an `NSException` that Swift cannot catch and that aborts the process
    /// with `SIGABRT` — when the descriptor's reader has been closed. This helper
    /// writes the bytes directly, sets `F_SETNOSIGPIPE` so a closed peer cannot
    /// deliver a fatal `SIGPIPE` regardless of the host process's global signal
    /// disposition, and reports `EPIPE`/`ECONNRESET` as
    /// ``ProcessPipeWriteOutcome/brokenPipe`` so a disappearing reader never
    /// crashes the process. It is the write-side mirror of the
    /// ``readDataToEndOfFileOrEmpty()`` family.
    ///
    /// Intended for blocking descriptors (the default for `Pipe`), which block
    /// until the write completes. A non-blocking descriptor is polled for
    /// writability between partial writes, but only up to a bounded timeout so a
    /// stalled peer can never park the calling thread (e.g. an actor's
    /// cooperative executor) indefinitely; on timeout the write returns
    /// ``ProcessPipeWriteOutcome/failed(errnoCode:)``.
    @discardableResult
    public func writeIgnoringBrokenPipe(_ data: Data) -> ProcessPipeWriteOutcome {
        guard !data.isEmpty else { return .completed }
        let fd = fileDescriptor
        // Belt-and-suspenders: never let this descriptor raise SIGPIPE, even if
        // the host process left SIGPIPE at its default (fatal) disposition.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)

        return data.withUnsafeBytes { rawBuffer -> ProcessPipeWriteOutcome in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return .completed
            }

            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    // No progress and no error reported: treat the sink as gone.
                    return processPipeLogWriteFailure(fd: fd, errnoCode: EIO)
                }

                let errorCode = errno
                switch errorCode {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    // Only reachable on a non-blocking descriptor. Wait for the
                    // descriptor to drain (or hang up) and retry; the retried
                    // write surfaces the concrete errno (e.g. EPIPE) for us.
                    guard processPipeWaitForWritable(fd) else {
                        return processPipeLogWriteFailure(fd: fd, errnoCode: errorCode)
                    }
                    continue
                case EPIPE, ECONNRESET:
                    processPipeWriterLogger.debug(
                        "processPipeWriter.brokenPipe fd=\(fd, privacy: .public) errno=\(Int(errorCode), privacy: .public)"
                    )
                    return .brokenPipe
                default:
                    return processPipeLogWriteFailure(fd: fd, errnoCode: errorCode)
                }
            }
            return .completed
        }
    }
}

private func processPipeLogWriteFailure(fd: Int32, errnoCode: Int32) -> ProcessPipeWriteOutcome {
    processPipeWriterLogger.warning(
        "processPipeWriter.writeFailed fd=\(fd, privacy: .public) errno=\(Int(errnoCode), privacy: .public) message=\(String(cString: strerror(errnoCode)), privacy: .public)"
    )
    return .failed(errnoCode: errnoCode)
}

/// Waits up to ``processPipeWritableWaitTimeoutMilliseconds`` for `fd` to become
/// writable, hung up, or errored. Returns `true` when the caller should retry the
/// write (a retry surfaces the concrete errno on hangup), `false` when the
/// descriptor is invalid, polling failed, or the wait timed out.
private func processPipeWaitForWritable(_ fd: Int32) -> Bool {
    let deadline = DispatchTime.now() + .milliseconds(Int(processPipeWritableWaitTimeoutMilliseconds))
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return false }
        let remainingMilliseconds = (deadline.uptimeNanoseconds - now) / 1_000_000
        descriptor.revents = 0
        let result = poll(&descriptor, 1, Int32(clamping: max(remainingMilliseconds, 1)))
        if result > 0 {
            let revents = descriptor.revents
            if (revents & Int16(POLLNVAL)) != 0 {
                return false
            }
            return (revents & Int16(POLLOUT | POLLHUP | POLLERR)) != 0
        }
        if result == 0 {
            return false
        }
        if errno == EINTR {
            continue
        }
        return false
    }
}
