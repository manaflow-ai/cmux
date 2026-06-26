import Foundation

// Safe to share across FileHandle callbacks and main-actor teardown: mutable
// pending-byte state lives in `RemoteTmuxStdoutBackpressureBudget`, and the
// AsyncStream continuation is the thread-safe handoff primitive.
final class RemoteTmuxStdoutPipeReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let budget: RemoteTmuxStdoutBackpressureBudget
    private let onOverflow: @MainActor @Sendable () -> Void

    init(
        maxPendingChunks: Int,
        maxPendingBytes: Int,
        onOverflow: @escaping @MainActor @Sendable () -> Void
    ) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(maxPendingChunks)
        )
        self.stream = stream
        self.continuation = continuation
        self.budget = RemoteTmuxStdoutBackpressureBudget(maxPendingBytes: maxPendingBytes)
        self.onOverflow = onOverflow
    }

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            self?.read(from: handle)
        }
    }

    func release(_ data: Data) {
        budget.release(byteCount: data.count)
    }

    func close() {
        budget.close()
        continuation.finish()
    }

    private func read(from handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            close()
            return
        }

        guard budget.reserve(byteCount: chunk.count) else {
            overflow(handle)
            return
        }

        switch continuation.yield(chunk) {
        case .enqueued:
            break
        case .dropped, .terminated:
            budget.release(byteCount: chunk.count)
            overflow(handle)
        @unknown default:
            budget.release(byteCount: chunk.count)
            overflow(handle)
        }
    }

    private func overflow(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        close()
        Task { @MainActor [onOverflow] in
            onOverflow()
        }
    }
}
