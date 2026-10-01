import Synchronization

/// Read-your-writes for compat reads without refetching the tree.
///
/// After every compat write is acknowledged, the service raises this to the
/// daemon event sequence the written session's connection has routed
/// (`DaemonConnection.eventSequence()`), which bounds every event the write
/// produced. A read then answers from the first published
/// `ControlSnapshot` whose topology reflects every raised sequence
/// (`ControlSnapshotStore.snapshot(reflecting:deadline:)`), usually the
/// current one. Global, not per client: the old CLI opens a socket per
/// command, so "my earlier write" spans connections. Sessions are keyed by
/// `ControlSessionInfo.id`; nil is the home session.
final class CompatWriteBarrier: Sendable {
    private let value = Mutex(ControlSequenceBarrier())

    var barrier: ControlSequenceBarrier { value.withLock { $0 } }

    /// The home session's sequence.
    var sequence: UInt64 { value.withLock { $0.home } }

    func raise(to sequence: UInt64, session: String? = nil) {
        value.withLock { barrier in
            if let session {
                barrier.sessions[session] = max(barrier.sessions[session] ?? 0, sequence)
            } else {
                barrier.home = max(barrier.home, sequence)
            }
        }
    }
}
