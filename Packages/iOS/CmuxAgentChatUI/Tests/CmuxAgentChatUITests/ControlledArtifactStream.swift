import CmuxAgentChat
import Foundation

/// Suspends after its first chunk so viewer tests can inspect and cancel mid-stream.
actor ControlledArtifactStream {
    private let chunks: [ChatArtifactChunk]
    private let resumeStream: AsyncStream<Void>
    private let resumeContinuation: AsyncStream<Void>.Continuation
    private var firstChunkDelivered = false
    private var cancelled = false
    private var firstChunkWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(chunks: [ChatArtifactChunk]) {
        self.chunks = chunks
        let pair = AsyncStream<Void>.makeStream()
        resumeStream = pair.stream
        resumeContinuation = pair.continuation
    }

    func fetch(
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        defer {
            if Task.isCancelled {
                markCancelled()
            }
        }

        for (index, chunk) in chunks.enumerated() {
            try await onChunk(chunk)
            if index == chunks.startIndex {
                markFirstChunkDelivered()
            }
            if index == chunks.startIndex, chunks.count > 1 {
                var iterator = resumeStream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        }
    }

    func resume() {
        resumeContinuation.yield()
    }

    func waitUntilFirstChunkDelivered() async {
        guard !firstChunkDelivered else { return }
        await withCheckedContinuation { continuation in
            firstChunkWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private func markFirstChunkDelivered() {
        firstChunkDelivered = true
        let waiters = firstChunkWaiters
        firstChunkWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func markCancelled() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
