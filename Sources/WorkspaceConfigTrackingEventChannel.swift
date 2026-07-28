import Foundation

@MainActor
final class WorkspaceConfigTrackingEventChannel {
    private let channel: (
        stream: AsyncStream<WorkspaceConfigTrackingEvent>,
        continuation: AsyncStream<WorkspaceConfigTrackingEvent>.Continuation
    )

    init(bufferCapacity: Int = 64) {
        precondition(bufferCapacity > 0)
        channel = AsyncStream<WorkspaceConfigTrackingEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferCapacity)
        )
    }

    var events: AsyncStream<WorkspaceConfigTrackingEvent> {
        channel.stream
    }

    func send(_ event: WorkspaceConfigTrackingEvent) {
        switch channel.continuation.yield(event) {
        case .dropped:
            // A full snapshot is cheaper and safer than trying to infer which
            // incremental event was evicted from the bounded buffer.
            channel.continuation.yield(.structuralChanged)
        case .enqueued, .terminated:
            break
        @unknown default:
            channel.continuation.yield(.structuralChanged)
        }
    }

    deinit {
        channel.continuation.finish()
    }
}
