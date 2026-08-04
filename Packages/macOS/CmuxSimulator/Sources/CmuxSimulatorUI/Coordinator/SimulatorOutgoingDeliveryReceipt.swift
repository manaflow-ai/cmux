import Foundation

/// Completes after every message queued before it has reached the pane client.
final class SimulatorOutgoingDeliveryReceipt: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async throws {
        for await _ in stream {}
        try Task.checkCancellation()
    }

    func finish() {
        continuation.finish()
    }
}
