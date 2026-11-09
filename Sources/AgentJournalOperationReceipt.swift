import Foundation

/// Completion receipt for an operation admitted to the agent journal consumer.
final class AgentJournalOperationReceipt: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = channel.stream
        continuation = channel.continuation
    }

    /// Waits until the consumer has reconciled the operation and its derived writes.
    func wait() async {
        for await _ in stream { return }
    }

    func finish() {
        continuation.yield(())
        continuation.finish()
    }
}
