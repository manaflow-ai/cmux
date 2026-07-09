import Darwin
import Foundation

// Sendable safety: mutable read-source and pending-byte state is confined to
// `queue`; DispatchSourceRead requires that delivery queue, and the AsyncStream
// continuation is the thread-safe handoff primitive.
final class RemoteTmuxStdoutPipeReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let maxReadChunkBytes: Int
    private let onOverflow: @MainActor @Sendable () -> Void
    private var handle: FileHandle?
    private var source: (any DispatchSourceRead)?
    private var pendingBytes = 0
    private var closed = false

    init(
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
        self.queue = DispatchQueue(
            label: "com.cmux.remote-tmux.stdout.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.maxReadChunkBytes = max(1, maxReadChunkBytes)
        self.onOverflow = onOverflow
    }

    func attach(to handle: FileHandle) {
        let fileDescriptor = handle.fileDescriptor
        queue.async { [weak self] in
            guard let self, !self.closed, self.source == nil else { return }
            self.handle = handle
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

    func close() {
        queue.async {
            self.finishOnQueue()
        }
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

        var buffer = [UInt8](repeating: 0, count: readByteCount(available: source.data))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }

        if bytesRead == 0 {
            finishOnQueue()
            return
        }

        if bytesRead < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            finishOnQueue()
            return
        }

        let chunk = Data(buffer[0..<bytesRead])
        guard reserve(byteCount: chunk.count) else {
            overflowOnQueue()
            return
        }

        switch continuation.yield(chunk) {
        case .enqueued:
            break
        case .dropped, .terminated:
            releaseOnQueue(byteCount: chunk.count)
            overflowOnQueue()
        @unknown default:
            releaseOnQueue(byteCount: chunk.count)
            overflowOnQueue()
        }
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
        self.source = nil
        sourceToCancel?.cancel()
        handle = nil
        continuation.finish()
    }
}
