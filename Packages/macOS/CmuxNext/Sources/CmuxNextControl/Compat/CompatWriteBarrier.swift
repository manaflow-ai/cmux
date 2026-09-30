import Synchronization

/// Read-your-writes for compat reads without refetching the tree.
///
/// After every compat write is acknowledged, the service raises this to the
/// daemon event sequence its connection has routed
/// (`DaemonConnection.eventSequence()`), which bounds every event the write
/// produced. A read then answers from the first published
/// `ControlSnapshot` whose topology reflects that sequence
/// (`ControlSnapshotStore.snapshot(reflecting:deadline:)`), usually the
/// current one. Global, not per client: the old CLI opens a socket per
/// command, so "my earlier write" spans connections.
final class CompatWriteBarrier: Sendable {
    private let value = Atomic<UInt64>(0)

    var sequence: UInt64 { value.load(ordering: .acquiring) }

    func raise(to sequence: UInt64) {
        value.max(sequence, ordering: .acquiringAndReleasing)
    }
}
