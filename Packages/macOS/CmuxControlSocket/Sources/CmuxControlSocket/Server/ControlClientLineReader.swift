internal import Darwin
internal import Dispatch
internal import Foundation

/// Blocking newline-framed reader for one accepted control-socket client,
/// lifted byte-faithfully from the legacy `TerminalController.handleClient`
/// read loop.
///
/// One instance serves one connection on one dedicated client-handler thread;
/// the type is intentionally not thread-safe. The reader never closes the
/// descriptor — connection ownership stays with the handler.
///
/// Framing contract (all legacy behavior, pinned by tests):
/// - Reads up to `bufferSize - 1` bytes per `read(2)` call.
/// - A chunk that is not valid UTF-8 is dropped wholesale (the legacy
///   `String(bytes:encoding:) ?? ""` coalesce).
/// - Lines are split on bare `\n` only. To preserve legacy framing, `\r\n`
///   does not terminate a line (clients must frame with bare `\n`). Returned
///   lines may be empty or whitespace-only.
/// - `shouldContinueReading` is consulted before each blocking `read(2)` and
///   periodically while an authorized connection is idle. It is never polled
///   between lines already buffered.
/// - EOF, a read error, or a `false` poll ends the stream (`nil`); buffered
///   bytes without a trailing newline are discarded, as before.
/// - While `initialLimits` remain active, raw bytes are counted cumulatively
///   before UTF-8 decoding, including invalid chunks and line delimiters, and
///   the absolute deadline is checked before buffered lines are returned.
public final class ControlClientLineReader {
    private let socket: Int32
    private var buffer: [UInt8]
    private var pendingBytes: [UInt8] = []
    private var pendingStartIndex = 0
    private var newlineSearchIndex = 0
    private var limitedBytesRead = 0
    private var limits: ControlClientLineReadLimits?
    private var deadlineUptimeNanoseconds: UInt64?
    private let continuationPollIntervalMilliseconds: Int32
    private let monotonicNowNanoseconds: @Sendable () -> UInt64

    /// Creates a reader for `socket`.
    /// - Parameters:
    ///   - socket: The connection's descriptor; not closed by the reader.
    ///   - bufferSize: Read buffer size; the legacy loop read at most
    ///     `bufferSize - 1` bytes per call.
    ///   - initialLimits: Optional resource bounds removed after authorization.
    ///   - continuationPollIntervalMilliseconds: Maximum idle time before
    ///     rechecking whether the connection remains authorized.
    ///   - monotonicNowNanoseconds: Monotonic time source used for deadlines.
    public init(
        socket: Int32,
        bufferSize: Int = 4096,
        initialLimits: ControlClientLineReadLimits? = nil,
        continuationPollIntervalMilliseconds: Int32 = 250,
        monotonicNowNanoseconds: (@Sendable () -> UInt64)? = nil
    ) {
        self.socket = socket
        self.buffer = [UInt8](repeating: 0, count: bufferSize)
        self.continuationPollIntervalMilliseconds = max(1, continuationPollIntervalMilliseconds)
        self.monotonicNowNanoseconds = monotonicNowNanoseconds ?? {
            DispatchTime.now().uptimeNanoseconds
        }
        limits = initialLimits
        if let initialLimits {
            let milliseconds = UInt64(clamping: max(0, initialLimits.timeoutMilliseconds))
            let (duration, overflowed) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
            let now = self.monotonicNowNanoseconds()
            let (deadline, additionOverflowed) = now.addingReportingOverflow(duration)
            deadlineUptimeNanoseconds = overflowed || additionOverflowed ? .max : deadline
        }
    }

    /// Removes preauthorization limits after the peer proves authorization.
    public func clearLimits() {
        limits = nil
        limitedBytesRead = 0
        deadlineUptimeNanoseconds = nil
    }

    /// Returns the next newline-terminated line (without the newline), or
    /// `nil` when the connection ended or `shouldContinueReading` returned
    /// `false` before a blocking read.
    /// - Parameter shouldContinueReading: Polled before each `read(2)` and at
    ///   the configured continuation interval while the client is idle.
    public func nextLine(shouldContinueReading: () -> Bool) -> String? {
        while true {
            guard deadlineHasNotExpired else { return nil }

            if let newlineIndex = nextBareNewlineIndex() {
                let line = String(
                    bytes: pendingBytes[pendingStartIndex..<newlineIndex],
                    encoding: .utf8
                ) ?? ""
                pendingStartIndex = newlineIndex + 1
                newlineSearchIndex = pendingStartIndex
                compactPendingBytesIfNeeded()
                return line
            }

            guard waitForReadReadinessBeforeDeadline(
                shouldContinueReading: shouldContinueReading
            ) else { return nil }
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { return nil }

            if let limits {
                let (totalBytesRead, overflowed) = limitedBytesRead.addingReportingOverflow(bytesRead)
                guard !overflowed, totalBytesRead <= limits.maximumBytes else { return nil }
                limitedBytesRead = totalBytesRead
            }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pendingBytes.append(contentsOf: chunk.utf8)
        }
    }

    private var deadlineHasNotExpired: Bool {
        guard let deadlineUptimeNanoseconds else { return true }
        return monotonicNowNanoseconds() < deadlineUptimeNanoseconds
    }

    private func nextBareNewlineIndex() -> Int? {
        while newlineSearchIndex < pendingBytes.count {
            let index = newlineSearchIndex
            newlineSearchIndex += 1
            guard pendingBytes[index] == 0x0A else { continue }
            if index > pendingStartIndex, pendingBytes[index - 1] == 0x0D {
                continue
            }
            return index
        }
        return nil
    }

    private func compactPendingBytesIfNeeded() {
        guard pendingStartIndex > 0 else { return }
        if pendingStartIndex == pendingBytes.count {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingStartIndex = 0
            newlineSearchIndex = 0
            return
        }
        guard pendingStartIndex >= buffer.count,
              pendingStartIndex >= pendingBytes.count / 2 else { return }
        pendingBytes.removeFirst(pendingStartIndex)
        newlineSearchIndex -= pendingStartIndex
        pendingStartIndex = 0
    }

    private func waitForReadReadinessBeforeDeadline(
        shouldContinueReading: () -> Bool
    ) -> Bool {
        while true {
            guard shouldContinueReading(),
                  let timeoutMilliseconds = nextReadinessPollTimeoutMilliseconds() else {
                return false
            }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let result = poll(
                &descriptor,
                1,
                timeoutMilliseconds
            )
            if result > 0 {
                return descriptor.revents & Int16(POLLIN | POLLHUP) != 0
            }
            if result == 0 { continue }
            guard errno == EINTR else { return false }
        }
    }

    private func nextReadinessPollTimeoutMilliseconds() -> Int32? {
        guard let deadlineUptimeNanoseconds else {
            return continuationPollIntervalMilliseconds
        }
        let now = monotonicNowNanoseconds()
        guard now < deadlineUptimeNanoseconds else { return nil }
        let remaining = deadlineUptimeNanoseconds - now
        let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
        return Int32(min(milliseconds, UInt64(continuationPollIntervalMilliseconds)))
    }
}
