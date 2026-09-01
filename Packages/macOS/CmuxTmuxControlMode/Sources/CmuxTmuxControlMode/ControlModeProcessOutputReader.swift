import Darwin
import Foundation
import Dispatch

/// Delivers process-pipe bytes in order and drains the descriptor after the
/// child reports termination.
///
/// `Process.terminationHandler` is not an EOF notification. The reader keeps
/// its descriptor source alive until the pipe reaches EOF, and it keeps the
/// published-but-not-released bytes within a fixed budget. All mutable state
/// is confined to the source's serial I/O executor.
final class ControlModeProcessOutputReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let maxReadChunkBytes: Int
    private let onOverflow: @Sendable () -> Void
    private var descriptor: Int32?
    private var source: (any DispatchSourceRead)?
    private var pendingBytes = 0
    private var closed = false
    private var overflowReported = false
    private var processExited = false

    /// Creates a reader attached to `handle` before the child is launched.
    ///
    /// The descriptor is duplicated and the dispatch source is fully
    /// configured before it is resumed. After initialization, all mutable
    /// lifecycle state is owned by `queue`; this avoids a synchronous queue
    /// hop while still making a short-lived child observable from its first
    /// byte. The gateway owns the caller's `FileHandle` and closes it after
    /// `Process.run()`; this reader owns the duplicate.
    convenience init?(
        readingFrom handle: FileHandle,
        label: String,
        maxPendingChunks: Int = 4096,
        maxPendingBytes: Int = 8 * 1024 * 1024,
        maxReadChunkBytes: Int = 64 * 1024,
        onOverflow: @escaping @Sendable () -> Void = {}
    ) {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        guard descriptor >= 0 else { return nil }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        self.init(
            descriptor: descriptor,
            label: label,
            maxPendingChunks: maxPendingChunks,
            maxPendingBytes: maxPendingBytes,
            maxReadChunkBytes: maxReadChunkBytes,
            onOverflow: onOverflow
        )
    }

    private init(
        descriptor: Int32,
        label: String,
        maxPendingChunks: Int,
        maxPendingBytes: Int,
        maxReadChunkBytes: Int,
        onOverflow: @escaping @Sendable () -> Void
    ) {
        let chunkLimit = max(1, maxReadChunkBytes)
        let bufferLimit = max(1, maxPendingBytes)
        let streamCapacity = max(1, min(maxPendingChunks, bufferLimit / chunkLimit + 1))
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(streamCapacity)
        )
        self.stream = stream
        self.continuation = continuation
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = bufferLimit
        self.maxReadChunkBytes = chunkLimit
        self.onOverflow = onOverflow
        self.descriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
        self.source = source
        source.setEventHandler { [weak self] in
            self?.readAvailableOnQueue()
        }
        source.setCancelHandler {}
        // Resume only after every stored property and handler is initialized.
        // The child is not launched until this initializer returns, so no
        // caller can close the reader while this setup is in progress.
        source.resume()
    }

    /// Marks process termination. The source stays active until all bytes
    /// already buffered by the kernel have been published and EOF is observed.
    func processDidExit() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.processExited = true
            self.readAvailableOnQueue()
        }
    }

    /// Stops delivery without promising unread bytes.
    func close() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    /// Releases one chunk after its consumer has admitted it to the gateway
    /// queue. This makes the byte budget cover both the stream buffer and the
    /// consumer's in-flight work.
    func release(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.pendingBytes = max(0, self.pendingBytes - data.count)
        }
    }

    private func readAvailableOnQueue() {
        guard !closed, let descriptor else { return }
        while !closed {
            switch readAndPublishOnQueue(from: descriptor) {
            case .published, .interrupted:
                continue
            case .wouldBlock:
                // A process-exit callback can run before the kernel has made
                // the final bytes visible. Keep the read source armed; EOF or
                // another read event is the authoritative completion signal.
                return
            case .ended:
                finishOnQueue()
                return
            }
        }
    }

    private func readAndPublishOnQueue(from descriptor: Int32) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maxReadChunkBytes)
        let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count > 0 {
            let data = Data(buffer[0..<count])
            guard data.count <= maxPendingBytes - pendingBytes else {
                overflowOnQueue()
                return .ended
            }
            pendingBytes += data.count
            switch continuation.yield(data) {
            case .enqueued:
                return .published
            case .dropped, .terminated:
                pendingBytes = max(0, pendingBytes - data.count)
                overflowOnQueue()
                return .ended
            @unknown default:
                pendingBytes = max(0, pendingBytes - data.count)
                overflowOnQueue()
                return .ended
            }
        }
        if count == 0 { return .ended }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .ended
    }

    private func overflowOnQueue() {
        guard !overflowReported else { return }
        overflowReported = true
        finishOnQueue()
        onOverflow()
    }

    private func finishOnQueue() {
        guard !closed else { return }
        closed = true
        pendingBytes = 0
        let source = source
        self.source = nil
        source?.cancel()
        if let descriptor {
            Darwin.close(descriptor)
            self.descriptor = nil
        }
        processExited = false
        continuation.finish()
    }

    private enum ReadResult {
        case published
        case interrupted
        case wouldBlock
        case ended
    }
}
