import Darwin
import Foundation

/// A bounded process-pipe reader that publishes every byte written before exit.
///
/// A process termination callback is not an EOF callback: it can run before a
/// readability source has delivered the pipe's final buffered bytes. This reader
/// keeps one serial owner for the descriptor and, when told the process exited,
/// drains the nonblocking descriptor before finishing its stream.
// Sendable safety: mutable descriptor, source, and byte-accounting state is
// confined to `queue`; AsyncStream is the thread-safe handoff primitive.
final class RemoteTmuxProcessOutputReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let maxReadChunkBytes: Int
    private let onOverflow: @MainActor @Sendable () -> Void
    private var handle: FileHandle?
    private var source: DispatchSourceRead?
    private var pendingBytes = 0
    private var closed = false

    init(
        label: String,
        maxPendingChunks: Int,
        maxPendingBytes: Int,
        maxReadChunkBytes: Int = 64 * 1024,
        onOverflow: @escaping @MainActor @Sendable () -> Void
    ) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(maxPendingChunks)
        )
        self.stream = stream
        self.continuation = continuation
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.maxReadChunkBytes = max(1, maxReadChunkBytes)
        self.onOverflow = onOverflow
    }

    func attach(to handle: FileHandle) {
        let fileDescriptor = handle.fileDescriptor
        queue.async { [weak self] in
            guard let self, !self.closed, self.source == nil else { return }
            self.handle = handle
            self.makeNonblocking(fileDescriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.readAvailable(from: fileDescriptor)
            }
            self.source = source
            source.resume()
        }
    }

    func release(_ data: Data) {
        release(byteCount: data.count)
    }

    /// Drains bytes already committed to the pipe, then finishes the stream.
    func processDidExit() {
        queue.async { [weak self] in
            self?.drainAfterProcessExit()
        }
    }

    /// Cancels the reader without promising delivery of unread bytes.
    func close() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    private func makeNonblocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func release(byteCount: Int) {
        guard byteCount > 0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingBytes = max(0, self.pendingBytes - byteCount)
        }
    }

    private func readAvailable(from fileDescriptor: Int32) {
        guard !closed, let source else { return }
        if readAndPublish(from: fileDescriptor, byteCount: readByteCount(available: source.data)) == .ended {
            finishOnQueue()
        }
    }

    private func drainAfterProcessExit() {
        guard !closed, let handle else {
            finishOnQueue()
            return
        }
        let fileDescriptor = handle.fileDescriptor
        while !closed {
            switch readAndPublish(from: fileDescriptor, byteCount: maxReadChunkBytes) {
            case .published, .interrupted:
                continue
            case .wouldBlock, .ended:
                finishOnQueue()
            }
        }
    }

    private func readAndPublish(
        from fileDescriptor: Int32,
        byteCount: Int
    ) -> RemoteTmuxPipeReadResult {
        var buffer = [UInt8](repeating: 0, count: max(1, byteCount))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead > 0 {
            let chunk = Data(buffer[0..<bytesRead])
            guard reserve(byteCount: chunk.count) else {
                overflowOnQueue()
                return .ended
            }
            switch continuation.yield(chunk) {
            case .enqueued:
                return .published
            case .dropped, .terminated:
                releaseOnQueue(byteCount: chunk.count)
                overflowOnQueue()
                return .ended
            @unknown default:
                releaseOnQueue(byteCount: chunk.count)
                overflowOnQueue()
                return .ended
            }
        }
        if bytesRead == 0 { return .ended }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .ended
    }

    private func readByteCount(available: UInt) -> Int {
        guard available > 0 else { return 1 }
        return max(1, min(maxReadChunkBytes, Int(min(available, UInt(maxReadChunkBytes)))))
    }

    private func reserve(byteCount: Int) -> Bool {
        guard byteCount > 0 else { return true }
        guard byteCount <= maxPendingBytes - pendingBytes else { return false }
        pendingBytes += byteCount
        return true
    }

    private func releaseOnQueue(byteCount: Int) {
        guard byteCount > 0 else { return }
        pendingBytes = max(0, pendingBytes - byteCount)
    }

    private func overflowOnQueue() {
        finishOnQueue()
        Task { @MainActor [onOverflow] in
            onOverflow()
        }
    }

    private func finishOnQueue() {
        guard !closed else { return }
        closed = true
        pendingBytes = 0
        let sourceToCancel = source
        source = nil
        sourceToCancel?.cancel()
        handle = nil
        continuation.finish()
    }
}
