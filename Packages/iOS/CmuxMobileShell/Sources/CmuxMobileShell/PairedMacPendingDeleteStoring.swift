/// Local outbox for paired-Mac backup tombstones that have not yet been
/// confirmed by a successful upload.
public protocol PairedMacPendingDeleteStoring: Sendable {
    /// Load pending tombstones for one account/team scope.
    func load(scope: String) async -> Set<String>

    /// Replace pending tombstones for one account/team scope.
    func save(_ ids: Set<String>, scope: String) async

    /// Clear all pending tombstones.
    func removeAll() async
}
