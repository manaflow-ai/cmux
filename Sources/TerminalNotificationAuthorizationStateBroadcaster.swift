import Foundation

@MainActor
final class TerminalNotificationAuthorizationStateBroadcaster {
    private var continuations: [UUID: AsyncStream<NotificationAuthorizationState>.Continuation] = [:]

    func stream(current state: NotificationAuthorizationState) -> AsyncStream<NotificationAuthorizationState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NotificationAuthorizationState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations[id] = nil
            }
        }
        return stream
    }

    func publish(_ state: NotificationAuthorizationState) {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
