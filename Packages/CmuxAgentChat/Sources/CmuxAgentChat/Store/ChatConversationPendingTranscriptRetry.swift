import Foundation

func makePendingTranscriptRetryTask(
    idleSleep: @escaping @Sendable (Duration) async -> Void,
    signalQueue: ChatConversationRunSignalQueue
) -> Task<Void, Never> {
    Task {
        for delay in [Duration.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)] {
            guard !Task.isCancelled else { return }
            await idleSleep(delay)
            guard !Task.isCancelled else { return }
            await signalQueue.enqueue(.retryPendingTranscript)
        }
    }
}
