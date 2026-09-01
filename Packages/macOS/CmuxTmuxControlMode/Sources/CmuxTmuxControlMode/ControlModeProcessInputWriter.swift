public import Darwin
public import Foundation
import Dispatch
import os

/// A bounded, non-blocking FIFO for bytes written to a control-mode process.
///
/// `FileHandle.write(contentsOf:)` can block when a remote peer stops reading.
/// This writer owns a duplicated descriptor and drains it from a dispatch write
/// source. Its mutable FIFO lives in one asynchronous worker, so protocol
/// callers never use a queue or a lock as a state mutex.
public final class ControlModeProcessInputWriter: @unchecked Sendable {
    private enum Command: Sendable {
        case attach(Int32)
        case data(Data)
        case writable
    }

    private struct AdmissionState: Sendable {
        var pendingBytes = 0
        var closed = false
        var failureReported = false
    }

    // The lock protects bounded admission and one synchronous failure
    // compare-and-set. FIFO mutation remains owned by the worker below.
    private let admission: OSAllocatedUnfairLock<AdmissionState>
    private let continuation: AsyncStream<Command>.Continuation
    private let worker: Task<Void, Never>
    private let maxRecordBytes: Int
    private let maxPendingBytes: Int
    private let reportFailure: @Sendable (String) -> Void

    /// Creates a writer with a bounded pending-byte budget.
    ///
    /// - Parameters:
    ///   - label: A diagnostic label for the worker's write source.
    ///   - maxPendingBytes: The maximum number of bytes waiting for the child.
    ///   - onFailure: Called once when the descriptor closes, the budget is
    ///     exceeded, or the producer outruns the bounded command stream.
    public init(
        label: String,
        maxPendingBytes: Int = 8 * 1024 * 1024,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let pendingLimit = max(1, maxPendingBytes)
        // Herdr records and cmux-tui input lines are chunked below this size.
        // Keeping the command stream bounded as well as the FIFO prevents a
        // stalled worker from retaining an unbounded number of Data values.
        let recordLimit = max(1, min(128 * 1024, pendingLimit))
        let commandCapacity = max(32, min(512, pendingLimit / recordLimit + 8))
        let (stream, continuation) = AsyncStream<Command>.makeStream(
            bufferingPolicy: .bufferingOldest(commandCapacity)
        )
        let admission = OSAllocatedUnfairLock(initialState: AdmissionState())
        let report: @Sendable (String) -> Void = { reason in
            let shouldReport = admission.withLock { state in
                guard !state.failureReported else { return false }
                state.failureReported = true
                return true
            }
            if shouldReport { onFailure(reason) }
        }

        self.admission = admission
        self.continuation = continuation
        self.maxRecordBytes = recordLimit
        self.maxPendingBytes = pendingLimit
        self.reportFailure = report
        self.worker = Task.detached(priority: .userInitiated) {
            await Self.run(
                stream: stream,
                continuation: continuation,
                label: label,
                maxPendingBytes: pendingLimit,
                maxRecordBytes: recordLimit,
                releaseAdmission: { byteCount in
                    admission.withLock { state in
                        state.pendingBytes = max(0, state.pendingBytes - byteCount)
                    }
                },
                resetAdmission: {
                    admission.withLock { state in
                        state.pendingBytes = 0
                        state.closed = true
                    }
                },
                reportFailure: report
            )
        }
    }

    deinit {
        worker.cancel()
        continuation.finish()
    }

    /// Attach to a pipe before launching the child.
    ///
    /// The writer duplicates the descriptor. Closing the writer therefore
    /// cannot invalidate the caller's `FileHandle`, and the child-side pipe
    /// has one explicit owner.
    public func attach(to handle: FileHandle) {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        guard descriptor >= 0 else {
            reportFailure("control-mode input descriptor could not be duplicated")
            return
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        switch continuation.yield(.attach(descriptor)) {
        case .enqueued:
            break
        case .dropped, .terminated:
            Darwin.close(descriptor)
            reportFailure("control-mode input worker is unavailable")
        @unknown default:
            Darwin.close(descriptor)
            reportFailure("control-mode input worker is unavailable")
        }
    }

    /// Enqueue one complete protocol record without waiting for the child.
    @discardableResult
    public func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard data.count <= maxRecordBytes else {
            reportFailure("control-mode input record exceeded its bounded size")
            close()
            return false
        }
        let admitted = admission.withLock { state -> Bool in
            guard !state.closed,
                  data.count <= maxPendingBytes - state.pendingBytes else {
                return false
            }
            state.pendingBytes += data.count
            return true
        }
        guard admitted else {
            reportFailure("control-mode input exceeded its bounded buffer")
            close()
            return false
        }
        switch continuation.yield(.data(data)) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            releaseAdmission(data.count)
            reportFailure("control-mode input worker exceeded its bounded command buffer")
            close()
            return false
        @unknown default:
            releaseAdmission(data.count)
            reportFailure("control-mode input worker exceeded its bounded command buffer")
            close()
            return false
        }
    }

    /// Cancel delivery and close the duplicated descriptor.
    public func close() {
        admission.withLock { state in
            state.closed = true
            state.pendingBytes = 0
        }
        worker.cancel()
        continuation.finish()
    }

    private func releaseAdmission(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        admission.withLock { state in
            state.pendingBytes = max(0, state.pendingBytes - byteCount)
        }
    }

    private static func run(
        stream: AsyncStream<Command>,
        continuation: AsyncStream<Command>.Continuation,
        label: String,
        maxPendingBytes: Int,
        maxRecordBytes: Int,
        releaseAdmission: @escaping @Sendable (Int) -> Void,
        resetAdmission: @escaping @Sendable () -> Void,
        reportFailure: @escaping @Sendable (String) -> Void
    ) async {
        var descriptor: Int32?
        var source: (any DispatchSourceWrite)?
        var sourceIsSuspended = true
        var pendingChunks: [Data] = []
        var nextChunkIndex = 0
        var nextByteOffset = 0
        var pendingBytes = 0
        var stopped = false

        func closeTransport() {
            guard !stopped else { return }
            stopped = true
            pendingChunks.removeAll(keepingCapacity: false)
            nextChunkIndex = 0
            nextByteOffset = 0
            pendingBytes = 0
            resetAdmission()
            if sourceIsSuspended {
                sourceIsSuspended = false
                source?.resume()
            }
            source?.cancel()
            source = nil
            if let fd = descriptor {
                Darwin.close(fd)
                descriptor = nil
            }
        }

        func disarmSource() {
            guard !sourceIsSuspended, source != nil else { return }
            sourceIsSuspended = true
            source?.suspend()
        }

        func armSource() {
            guard sourceIsSuspended, let source else { return }
            sourceIsSuspended = false
            source.resume()
        }

        func compact() {
            guard nextChunkIndex > 0 else { return }
            guard nextChunkIndex == pendingChunks.count
                    || (nextChunkIndex >= 64 && nextChunkIndex * 2 >= pendingChunks.count)
            else { return }
            pendingChunks.removeFirst(nextChunkIndex)
            nextChunkIndex = 0
        }

        func flush() -> Bool {
            guard !stopped else { return false }
            // Data may arrive before the caller attaches the child pipe. Keep
            // it in the bounded FIFO and flush it as soon as `.attach` lands.
            guard let descriptor else { return true }
            while nextChunkIndex < pendingChunks.count {
                let chunk = pendingChunks[nextChunkIndex]
                guard nextByteOffset < chunk.count else {
                    nextChunkIndex += 1
                    nextByteOffset = 0
                    continue
                }
                let written = chunk.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: nextByteOffset),
                        rawBuffer.count - nextByteOffset
                    )
                }
                if written > 0 {
                    nextByteOffset += written
                    pendingBytes -= written
                    releaseAdmission(written)
                    if nextByteOffset == chunk.count {
                        nextChunkIndex += 1
                        nextByteOffset = 0
                    }
                    compact()
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
                reportFailure("control-mode input pipe closed")
                closeTransport()
                return false
            }
            compact()
            if nextChunkIndex >= pendingChunks.count { disarmSource() }
            return true
        }

        defer { closeTransport() }
        for await command in stream {
            if Task.isCancelled { break }
            switch command {
            case .attach(let newDescriptor):
                if let oldSource = source {
                    if sourceIsSuspended {
                        sourceIsSuspended = false
                        oldSource.resume()
                    }
                    oldSource.cancel()
                }
                if let oldDescriptor = descriptor { Darwin.close(oldDescriptor) }
                descriptor = newDescriptor
                sourceIsSuspended = true
                let writeSource = DispatchSource.makeWriteSource(
                    fileDescriptor: newDescriptor,
                    queue: DispatchQueue(label: label, qos: .userInitiated)
                )
                writeSource.setEventHandler {
                    // The source callback only signals the worker. It does not
                    // touch FIFO state from the dispatch queue.
                    continuation.yield(.writable)
                }
                writeSource.setCancelHandler {}
                source = writeSource
                writeSource.resume()
                writeSource.suspend()
                // Data may have been admitted before the child pipe was
                // attached. The source must be armed before the first flush
                // can observe EAGAIN, otherwise no writable event will wake
                // the worker and the FIFO can remain stranded forever.
                if pendingBytes > 0 { armSource() }
                _ = flush()
            case .data(let data):
                guard data.count <= maxRecordBytes else {
                    reportFailure("control-mode input record exceeded its bounded size")
                    closeTransport()
                    return
                }
                guard data.count <= maxPendingBytes - pendingBytes else {
                    reportFailure("control-mode input exceeded its bounded buffer")
                    closeTransport()
                    return
                }
                pendingChunks.append(data)
                pendingBytes += data.count
                if descriptor != nil { armSource() }
                guard flush() else { return }
            case .writable:
                guard flush() else { return }
            }
        }
    }
}
