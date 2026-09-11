import Foundation
public import Observation

/// Publishes workspace pane-topology changes to independent sidebar subscribers.
///
/// Each workspace owns a model and calls ``layoutDidChange()`` after a split,
/// pane close, or pane-collapse move. Consumers read ``changes()`` and rebuild
/// their immutable snapshot from the workspace's authoritative pane topology.
@MainActor
@Observable
public final class WorkspaceSidebarLayoutObservationModel {
    /// The wrapping generation of published topology changes, starting at zero.
    @ObservationIgnored
    public private(set) var changeGeneration: UInt64 = 0
    @ObservationIgnored
    private var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored
    private var hasUnobservedChange = false

    /// Creates an independent topology signal with no pending changes.
    public init() {}

    deinit {
        for continuation in changeObservers.values {
            continuation.finish()
        }
    }

    /// Subscribes to coalesced topology changes without retaining the model.
    ///
    /// A change made without a subscriber is replayed to the next subscriber.
    /// Every active subscriber buffers at most one pending invalidation. Streams
    /// finish when the model is released, and cancellation removes a subscriber.
    ///
    /// - Returns: An independently subscribed stream of snapshot invalidations.
    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            if hasUnobservedChange {
                hasUnobservedChange = false
                continuation.yield(())
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    /// Invalidates every subscriber after a pane split, close, or collapse.
    public func layoutDidChange() {
        changeGeneration &+= 1
        guard !changeObservers.isEmpty else {
            hasUnobservedChange = true
            return
        }

        var delivered = false
        var terminatedObserverIDs: [UUID] = []
        for (id, continuation) in changeObservers {
            if case .terminated = continuation.yield(()) {
                terminatedObserverIDs.append(id)
            } else {
                delivered = true
            }
        }
        for id in terminatedObserverIDs {
            changeObservers[id] = nil
        }
        if !delivered {
            hasUnobservedChange = true
        }
    }
}
