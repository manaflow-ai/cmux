import Foundation

/// Bounded per-panel change batching. Repeated events for one machine coalesce,
/// and a slow consumer never loses another machine's update to a stream overflow.
@MainActor
public final class VMResourceStatsSubscription {
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    /// Nil requests a complete refresh (initial subscription or overflow).
    private var pendingMachineIDs: Set<String>?

    public init(onTermination: @escaping @Sendable () -> Void) {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
        continuation.onTermination = { _ in onTermination() }
        continuation.yield(())
    }

    func markChanged(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if var pending = pendingMachineIDs {
            pending.formUnion(ids)
            pendingMachineIDs = pending.count > 256 ? nil : pending
        }
        continuation.yield(())
    }

    public func takeMachineIDs() -> Set<String>? {
        defer { pendingMachineIDs = [] }
        return pendingMachineIDs
    }
}
