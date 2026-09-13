import Foundation
import Observation

/// Invalidates sidebar projections after the workspace's authoritative Cloud binding changes.
@MainActor
@Observable
final class WorkspaceSidebarCloudWorkspaceObservationModel {
    private(set) var revision: UInt64 = 0
    @ObservationIgnored
    private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    /// Replays the current revision to every subscriber, then coalesces unread changes.
    func changes() -> AsyncStream<UInt64> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(revision)
            // AsyncStream termination is a nonisolated callback boundary.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    /// Signals a completed binding mutation without keeping a second copy of the binding.
    func cloudBindingDidChange() {
        revision &+= 1
        var terminatedIDs: [UUID] = []
        for (id, continuation) in observers {
            if case .terminated = continuation.yield(revision) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            observers[id] = nil
        }
    }
}
