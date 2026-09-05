internal import Dispatch
public import Foundation
internal import Darwin
internal import os

/// Bridges one non-blocking control-socket descriptor into an async line
/// reader. The descriptor is never closed by this type; its connection owner
/// retains that responsibility.
///
/// The read source is the sanctioned low-level socket-I/O bridge. It drains
/// until `EAGAIN`, finishes on EOF/error, and cancels itself on termination so
/// an EOF-ready descriptor cannot spin forever in a kqueue/Dispatch event loop.
/// One task must own the reader; concurrent calls to ``nextLine`` are invalid.
// @unchecked Sendable is safe because one connection task owns the mutable
// parser; DispatchSource callbacks publish only immutable Data chunks through
// the AsyncStream continuation.
public final class ControlClientAsyncLineReader: @unchecked Sendable {
    private final class SourceBox: @unchecked Sendable {
        var source: (any DispatchSourceRead)?
        /// Reused by `drain`, which runs serially on the read source's queue,
        /// so each readable event does not reallocate a 64 KiB buffer.
        var readBuffer = [UInt8](repeating: 0, count: ControlClientAsyncLineReader.readChunkSize)
    }

    /// The revocation source only needs its cancellation handle; keeping it
    /// separate from ``SourceBox`` avoids allocating a second read buffer for
    /// connections that listen for authorization revocation.
    // @unchecked Sendable is safe because the source handle is touched only by
    // the revocation source's serial utility queue and its cancellation path.
    private final class RevocationSourceBox: @unchecked Sendable {
        var source: (any DispatchSourceRead)?
    }

    /// Tracks bytes waiting in the stream and bytes retained by the line
    /// parser. The two counters share one budget for each connection.
    struct BufferedByteAccounting: Sendable {
        var queued = 0
        var pending = 0
        /// Records a terminal rejection when the shared byte budget is
        /// exceeded; the read source is finished immediately afterward.
        var didRejectForMaximum = false
    }

    private let socket: Int32
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    private let source: any DispatchSourceRead
    private let revocationSource: (any DispatchSourceRead)?
    /// One-shot idle deadline carried over from SO_RCVTIMEO. DispatchSource
    /// is the low-level descriptor/timer bridge; it never blocks the task.
    private let idleReadTimer: (any DispatchSourceTimer)?
    private var pendingBytes: [UInt8] = []
    private var pendingStartIndex = 0
    private var newlineSearchIndex = 0
    private var limits: ControlClientLineReadLimits?
    private var limitedBytesRead = 0
    private var deadlineUptimeNanoseconds: UInt64? = nil
    private var deadlineTask: Task<Void, Never>? = nil
    private let monotonicNowNanoseconds: @Sendable () -> UInt64
    private let maximumBufferedBytes: Int
    /// Shared byte accounting for stream-queued and parser-pending input.
    /// Written by the drain callback (utility queue) and the reader task, so
    /// it needs its own gate. Internal visibility lets the package test target
    /// inspect the source-of-truth counters through `@testable import`.
    // Lock carve-out: the read-source callback and the one owning reader task
    // must reserve/move bytes atomically without an async hop at this low-level
    // socket bridge. The lock never spans an await or protects parser work.
    internal let bufferedByteAccounting: OSAllocatedUnfairLock<BufferedByteAccounting>
    // The deadline task and the single reader task may finish/cancel on
    // different executors. This tiny gate protects only the active-limit bit;
    // command buffering remains owned by the reader task.
    private let limitsActive: OSAllocatedUnfairLock<Bool>

    /// Creates an async reader over a non-blocking descriptor.
    ///
    /// - Parameters:
    ///   - socket: The accepted descriptor. It is changed to `O_NONBLOCK`.
    ///   - initialLimits: Optional preauthorization byte/deadline limits.
    ///   - authorizationRevocationSignal: Signal that finishes an idle read.
    ///   - maximumBufferedBytes: Defensive cap for the combined stream-queued
    ///     and parser-pending input bytes on one connection.
    ///   - monotonicNowNanoseconds: Injectable monotonic clock for tests.
    public init(
        socket: Int32,
        initialLimits: ControlClientLineReadLimits? = nil,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal? = nil,
        maximumBufferedBytes: Int = 16 * 1024 * 1024,
        monotonicNowNanoseconds: (@Sendable () -> UInt64)? = nil
    ) {
        self.socket = socket
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        let bufferedByteAccounting = OSAllocatedUnfairLock(
            initialState: BufferedByteAccounting()
        )
        self.bufferedByteAccounting = bufferedByteAccounting
        self.limitsActive = OSAllocatedUnfairLock(initialState: initialLimits != nil)
        self.monotonicNowNanoseconds = monotonicNowNanoseconds ?? {
            DispatchTime.now().uptimeNanoseconds
        }
        _ = Self.makeNonBlocking(socket)

        // A command connection is FIFO and bounded by BYTES, not by a chunk
        // count: `read(2)` may return arbitrarily short chunks (one per
        // readable event), so an element-count policy would close a valid
        // request long before the byte cap (128 one-byte chunks vs 16 MiB).
        // The drain callback reserves every yielded byte against the shared
        // stream-plus-parser `maximumBufferedBytes` budget and fails the
        // connection closed when a client pipelines past the cap; the stream
        // itself is unbounded because the byte gate is what bounds it.
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let streamContinuation = stream.continuation
        continuation = streamContinuation
        iterator = stream.stream.makeAsyncIterator()

        let sourceBox = SourceBox()
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: socket,
            queue: DispatchQueue.global(qos: .utility)
        )
        let byteCapForDrain = self.maximumBufferedBytes
        readSource.setEventHandler { [streamContinuation, sourceBox, bufferedByteAccounting] in
            Self.drain(
                socket: socket,
                continuation: streamContinuation,
                sourceBox: sourceBox,
                bufferedByteAccounting: bufferedByteAccounting,
                maximumBufferedBytes: byteCapForDrain
            )
        }
        readSource.setCancelHandler { [streamContinuation, sourceBox] in
            sourceBox.source = nil
            streamContinuation.finish()
        }
        sourceBox.source = readSource
        source = readSource

        let idleReadTimer = Self.makeIdleReadTimer(
            socket: socket,
            continuation: streamContinuation
        )
        self.idleReadTimer = idleReadTimer

        if let signalDescriptor = authorizationRevocationSignal?.readFileDescriptor,
           signalDescriptor >= 0 {
            let duplicate = dup(signalDescriptor)
            if duplicate < 0 {
                revocationSource = nil
            } else {
                _ = fcntl(duplicate, F_SETFD, FD_CLOEXEC)
                let revocationBox = RevocationSourceBox()
                let revocation = DispatchSource.makeReadSource(
                    fileDescriptor: duplicate,
                    queue: DispatchQueue.global(qos: .utility)
                )
                revocation.setEventHandler { [streamContinuation, revocationBox] in
                    streamContinuation.finish()
                    revocationBox.source?.cancel()
                }
                revocation.setCancelHandler { [revocationBox] in
                    revocationBox.source = nil
                    close(duplicate)
                }
                revocationBox.source = revocation
                revocationSource = revocation
            }
        } else {
            revocationSource = nil
        }

        limits = initialLimits
        if let initialLimits {
            let milliseconds = UInt64(clamping: max(0, initialLimits.timeoutMilliseconds))
            let (duration, overflowed) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
            let now = self.monotonicNowNanoseconds()
            let (deadline, additionOverflowed) = now.addingReportingOverflow(duration)
            deadlineUptimeNanoseconds = overflowed || additionOverflowed ? .max : deadline
            if !overflowed {
                let deadlineContinuation = continuation
                deadlineTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: duration)
                    } catch {
                        return
                    }
                    guard self?.limitsActive.withLock({ $0 }) == true else { return }
                    deadlineContinuation.finish()
                }
            }
        }

        readSource.activate()
        revocationSource?.activate()
    }

    deinit {
        deadlineTask?.cancel()
        source.cancel()
        revocationSource?.cancel()
        idleReadTimer?.cancel()
        continuation.finish()
    }

    /// Removes preauthorization limits after the peer proves authorization.
    public func clearLimits() {
        limits = nil
        limitsActive.withLock { $0 = false }
        limitedBytesRead = 0
        deadlineUptimeNanoseconds = nil
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    /// Returns the next newline-terminated UTF-8 line, or `nil` on EOF,
    /// revocation, timeout, cancellation, or a malformed/oversized stream.
    /// Bare `\n` framing and the legacy CRLF behavior are preserved.
    public func nextLine(
        shouldContinueReading: @Sendable @escaping () -> Bool
    ) async -> String? {
        while !Task.isCancelled {
            guard deadlineHasNotExpired, shouldContinueReading() else { return nil }

            if let newlineIndex = nextBareNewlineIndex() {
                let consumedByteCount = newlineIndex + 1 - pendingStartIndex
                let decoded = String(
                    bytes: pendingBytes[pendingStartIndex..<newlineIndex],
                    encoding: .utf8
                )
                pendingStartIndex = newlineIndex + 1
                newlineSearchIndex = pendingStartIndex
                releasePendingBytes(consumedByteCount)
                compactPendingBytesIfNeeded()
                // Invalid UTF-8 lines are dropped exactly like the blocking
                // reader, without discarding subsequent framed lines.
                if let decoded { return decoded }
                continue
            }

            scheduleIdleReadDeadline()
            let nextChunk = await withTaskCancellationHandler {
                await iterator.next()
            } onCancel: {
                source.cancel()
                revocationSource?.cancel()
                idleReadTimer?.cancel()
                continuation.finish()
            }
            idleReadTimer?.schedule(
                deadline: .distantFuture,
                repeating: .never
            )
            guard let chunk = nextChunk else { return nil }
            guard !chunk.isEmpty else { continue }
            guard moveQueuedBytesToPending(chunk.count) else { return nil }
            if limitsActive.withLock({ $0 }), let limits {
                let (total, overflowed) = limitedBytesRead.addingReportingOverflow(chunk.count)
                guard !overflowed, total <= limits.maximumBytes else { return nil }
                limitedBytesRead = total
            }
            pendingBytes.append(contentsOf: chunk)
            guard pendingBytes.count - pendingStartIndex <= maximumBufferedBytes else {
                return nil
            }
        }
        return nil
    }

    /// Explicitly terminates the reader's event sources.
    public func cancel() {
        source.cancel()
        revocationSource?.cancel()
        idleReadTimer?.cancel()
        continuation.finish()
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

    /// Moves a yielded chunk from the stream queue into the parser budget.
    private func moveQueuedBytesToPending(_ count: Int) -> Bool {
        bufferedByteAccounting.withLock { state in
            let (newPending, pendingOverflowed) = state.pending.addingReportingOverflow(count)
            guard state.queued >= count, !pendingOverflowed else { return false }
            state.queued -= count
            state.pending = newPending
            return true
        }
    }

    /// Releases bytes consumed by a complete (or invalid) framed line.
    private func releasePendingBytes(_ count: Int) {
        bufferedByteAccounting.withLock { state in
            state.pending = state.pending >= count ? state.pending - count : 0
        }
    }

    private func compactPendingBytesIfNeeded() {
        guard pendingStartIndex > 0 else { return }
        if pendingStartIndex == pendingBytes.count {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingStartIndex = 0
            newlineSearchIndex = 0
            return
        }
        guard pendingStartIndex >= 4096,
              pendingStartIndex >= pendingBytes.count / 2 else { return }
        pendingBytes.removeFirst(pendingStartIndex)
        newlineSearchIndex -= pendingStartIndex
        pendingStartIndex = 0
    }

    private static func makeNonBlocking(_ socket: Int32) -> Int32? {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0 else { return errno }
        guard fcntl(socket, F_SETFL, flags | O_NONBLOCK) >= 0 else { return errno }
        return nil
    }

    private static func makeIdleReadTimer(
        socket: Int32,
        continuation: AsyncStream<Data>.Continuation
    ) -> (any DispatchSourceTimer)? {
        var timeout = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, &length) == 0,
              timeout.tv_sec > 0 || timeout.tv_usec > 0 else {
            return nil
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.setEventHandler {
            continuation.finish()
            timer.schedule(deadline: .distantFuture, repeating: .never)
        }
        timer.activate()
        return timer
    }

    private func scheduleIdleReadDeadline() {
        guard let idleReadTimer,
              let timeoutNanoseconds = socketReceiveTimeoutNanoseconds else { return }
        idleReadTimer.schedule(
            deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)),
            repeating: .never
        )
    }

    private var socketReceiveTimeoutNanoseconds: UInt64? {
        var timeout = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, &length) == 0,
              timeout.tv_sec >= 0,
              timeout.tv_usec >= 0 else { return nil }
        let seconds = UInt64(timeout.tv_sec)
        let micros = UInt64(timeout.tv_usec)
        let (secondsNanos, secondsOverflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (microsNanos, microsOverflowed) = micros.multipliedReportingOverflow(by: 1_000)
        let (total, additionOverflowed) = secondsNanos.addingReportingOverflow(microsNanos)
        return secondsOverflowed || microsOverflowed || additionOverflowed ? .max : total
    }

    /// Bytes read per `read(2)` call while draining the descriptor.
    static let readChunkSize = 64 * 1024

    private static func drain(
        socket: Int32,
        continuation: AsyncStream<Data>.Continuation,
        sourceBox: SourceBox,
        bufferedByteAccounting: OSAllocatedUnfairLock<BufferedByteAccounting>,
        maximumBufferedBytes: Int
    ) {
        while true {
            let count = sourceBox.readBuffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(socket, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let accepted = bufferedByteAccounting.withLock { state -> Bool in
                    let (newQueued, queuedOverflowed) = state.queued.addingReportingOverflow(count)
                    guard !queuedOverflowed else {
                        state.didRejectForMaximum = true
                        return false
                    }
                    let (total, totalOverflowed) = newQueued.addingReportingOverflow(state.pending)
                    guard !totalOverflowed, total <= maximumBufferedBytes else {
                        state.didRejectForMaximum = true
                        return false
                    }
                    state.queued = newQueued
                    return true
                }
                guard accepted else {
                    continuation.finish()
                    sourceBox.source?.cancel()
                    return
                }
                if case .dropped = continuation.yield(Data(sourceBox.readBuffer[0..<count])) {
                    bufferedByteAccounting.withLock { state in
                        state.queued = state.queued >= count ? state.queued - count : 0
                    }
                    continuation.finish()
                    sourceBox.source?.cancel()
                    return
                }
                continue
            }
            if count == 0 {
                continuation.finish()
                sourceBox.source?.cancel()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            continuation.finish()
            sourceBox.source?.cancel()
            return
        }
    }
}

/// Asynchronously writes one connection's responses without parking a thread
/// when a client applies backpressure. One writer task owns the instance.
// @unchecked Sendable is safe because one connection task performs all writes;
// the one-shot writable source communicates only through its continuation.
public final class ControlClientAsyncWriter: @unchecked Sendable {
    private final class SourceBox: @unchecked Sendable {
        var source: (any DispatchSourceWrite)?
    }

    private let socket: Int32

    /// Creates a writer over a non-blocking descriptor.
    public init(socket: Int32) {
        self.socket = socket
        _ = Self.makeNonBlocking(socket)
    }

    /// Writes all bytes, suspending on `EAGAIN`; returns false after EOF,
    /// cancellation, or a non-retryable write error.
    public func writeAll(_ data: Data) async -> Bool {
        var offset = 0
        while offset < data.count, !Task.isCancelled {
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    socket,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard await waitForWritable() else { return false }
                continue
            }
            return false
        }
        return offset == data.count
    }

    /// Cancels future write notifications.
    public func cancel() {
        // Each would-block wait owns a one-shot source and observes task
        // cancellation. There is no persistent writable source to suspend.
    }

    private static func makeNonBlocking(_ socket: Int32) -> Int32? {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0 else { return errno }
        guard fcntl(socket, F_SETFL, flags | O_NONBLOCK) >= 0 else { return errno }
        return nil
    }

    private func waitForWritable() async -> Bool {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let streamContinuation = stream.continuation
        let sourceBox = SourceBox()
        let writeSource = DispatchSource.makeWriteSource(
            fileDescriptor: socket,
            queue: DispatchQueue.global(qos: .utility)
        )
        writeSource.setEventHandler { [streamContinuation, sourceBox] in
            streamContinuation.yield(())
            streamContinuation.finish()
            sourceBox.source?.cancel()
        }
        writeSource.setCancelHandler {
            streamContinuation.finish()
        }
        sourceBox.source = writeSource
        writeSource.activate()

        var iterator = stream.stream.makeAsyncIterator()
        let writable: Void? = await withTaskCancellationHandler {
            await iterator.next()
        } onCancel: {
            writeSource.cancel()
            streamContinuation.finish()
        }
        return writable != nil
    }
}
