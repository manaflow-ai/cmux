import Darwin
import Foundation

/// A bounded process-pipe reader that publishes every byte written before exit.
///
/// A process termination callback is not an EOF callback. This reader owns a
/// duplicated, nonblocking descriptor and keeps its read source alive until
/// EOF. The descriptor and all byte-accounting state are confined to the
/// source's serial executor; `AsyncStream` is the only cross-task handoff.
final class RemoteTmuxProcessOutputReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let maxReadChunkBytes: Int
    private let onOverflow: @MainActor @Sendable () -> Void
    private var descriptor: Int32?
    private var source: DispatchSourceRead?
    private var pendingBytes = 0
    private var closed = false
    private var processExited = false
    private var overflowReported = false

    /// Creates a reader attached to `handle` before the child is launched.
    ///
    /// The descriptor is duplicated and the dispatch source is resumed before
    /// this initializer returns. That makes an immediately failing child
    /// observable without a synchronous queue hop at the launch boundary.
    convenience init?(
        readingFrom handle: FileHandle,
        label: String,
        maxPendingChunks: Int,
        maxPendingBytes: Int,
        maxReadChunkBytes: Int = 64 * 1024,
        onOverflow: @escaping @MainActor @Sendable () -> Void
    ) {
        let duplicated = Darwin.dup(handle.fileDescriptor)
        guard duplicated >= 0 else { return nil }
        let flags = fcntl(duplicated, F_GETFL)
        if flags >= 0 { _ = fcntl(duplicated, F_SETFL, flags | O_NONBLOCK) }
        self.init(
            descriptor: duplicated,
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
        onOverflow: @escaping @MainActor @Sendable () -> Void
    ) {
        let chunkLimit = max(1, maxReadChunkBytes)
        let byteLimit = max(1, maxPendingBytes)
        let streamCapacity = max(1, min(maxPendingChunks, byteLimit / chunkLimit + 1))
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(streamCapacity)
        )
        self.stream = stream
        self.continuation = continuation
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = byteLimit
        self.maxReadChunkBytes = chunkLimit
        self.onOverflow = onOverflow
        self.descriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
        self.source = source
        source.setEventHandler { [weak self] in
            self?.readAvailableOnQueue()
        }
        source.setCancelHandler {}
        // The source is fully initialized before it is resumed. No caller can
        // close this reader until the initializer has returned.
        source.resume()
    }

    /// Marks process termination. The source remains active until EOF drains
    /// bytes already present in the kernel pipe.
    func processDidExit() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.processExited = true
            self.readAvailableOnQueue()
        }
    }

    /// Cancels delivery without promising unread bytes.
    func close() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    /// Releases one chunk after its consumer has admitted it to the parser or
    /// diagnostics queue. The pending-byte budget therefore covers both the
    /// stream buffer and consumer work that has not completed yet.
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
                // EAGAIN is an intermediate state, including when termination
                // beats the final kernel read. The source remains armed for
                // the EOF event.
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
        Task { @MainActor [onOverflow] in
            onOverflow()
        }
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
