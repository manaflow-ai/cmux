import Foundation
import Observation

/// The tmux mirror that owns a workspace, as Files and other projections see it.
struct RemoteTmuxMirrorLink: Equatable {
    let host: RemoteTmuxHost
    var isConnected: Bool
}

/// Owns a workspace's tmux mirror link: set when a mirror attaches, updated on each
/// control-connection transition, and cleared when the mirror detaches.
@MainActor
@Observable
final class WorkspaceRemoteTmuxMirrorState {
    var link: RemoteTmuxMirrorLink? {
        didSet {
            guard oldValue != link else { return }
            linkDidChange()
        }
    }
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

    private func linkDidChange() {
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
