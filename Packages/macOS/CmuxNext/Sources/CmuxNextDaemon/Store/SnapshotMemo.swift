/// What the store knows about its last applied live snapshot, so the next one touches only what
/// changed (plans/cmux-next/main-thread-budget.md; the sweep's daemon-store-apply group).
///
/// `applied` holds each workspace's snapshot as the last live snapshot gave it. A workspace whose
/// new snapshot equals that one, and that no event touched since (`dirty`), has records that equal
/// the snapshot already, except the tabs in `dirtyTabs`: the apply skips it and re-applies only
/// those tabs. Anything the memo cannot vouch for makes the next
/// apply a full one: no snapshot of this connection yet, a new daemon generation or registry, a
/// launch snapshot, or a confirmed write it could not attribute to a workspace (`untracked`).
struct SnapshotMemo {
    /// The last live snapshot's workspaces by identity (``WorkspaceModel/identity(_:)``).
    var applied: [String: WorkspaceSnapshot] = [:]
    /// The last live snapshot's workspace identities in its order.
    var order: [String] = []
    /// The confirmed workspace list right after that snapshot applied. Held here, any later write to the store's list
    /// (an event, an intent's overlay) copies it to a new buffer, so the same buffer proves the list is unchanged in O(1).
    var list: [WorkspaceModel] = []
    /// The connection it belongs to (``DaemonStore/connectionEpoch``).
    var epoch: Int?
    var generation: DaemonGeneration?
    var registryID: String?
    /// Workspaces an applied structural event changed since that snapshot.
    var dirty: Set<String> = []
    /// Tabs whose whole-value field (title, size, exit) an applied event wrote since that snapshot,
    /// re-applied one by one when their workspace is otherwise untouched.
    var dirtyTabs: Set<SurfaceID> = []
    /// A confirmed write since that snapshot that names no workspace: the next apply is full.
    var untracked = false
    /// Increases with every snapshot apply (an off-main diff computed against an older memo is
    /// recomputed).
    var revision: UInt64 = 0

    /// Forgets everything: the next snapshot applies in full.
    mutating func reset() {
        self = SnapshotMemo(revision: revision &+ 1)
    }
}

extension Array {
    /// Whether `other` is this very array value: the same storage, so no write since one was copied from the other
    /// (a write to storage two values share copies it first). O(1); false says nothing about the elements.
    func sharesStorage(with other: Self) -> Bool {
        count == other.count && withUnsafeBufferPointer { mine in other.withUnsafeBufferPointer { $0.baseAddress == mine.baseAddress } }
    }
}
