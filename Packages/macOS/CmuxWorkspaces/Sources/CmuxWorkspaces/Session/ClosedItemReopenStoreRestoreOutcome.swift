public import Foundation

/// The result of one store-backed reopen attempt the
/// ``ClosedItemReopenHosting`` performs on behalf of
/// ``ClosedItemReopenCoordinator``.
///
/// The store owns the candidate iteration internally (`restoreFirstRestorable`),
/// so the coordinator cannot see which records failed without this carrier. The
/// host returns whether a record was restored and the ids of every record whose
/// restore the store attempted and rejected this call, so the coordinator can
/// keep accumulating them into the `excluding` set across the interleaved
/// legacy-browser-stack loop, reproducing the legacy `failedStoreRecordIds`
/// bookkeeping exactly.
public struct ClosedItemReopenStoreRestoreOutcome: Sendable {
    /// Whether the store restored a record on this attempt.
    public let didRestore: Bool

    /// The ids of records the store attempted to restore and that failed on this
    /// attempt. The coordinator unions these into the running exclusion set so a
    /// failed record is never retried within a single reopen flow.
    public let failedRecordIds: Set<UUID>

    /// Creates a store-restore outcome.
    public init(didRestore: Bool, failedRecordIds: Set<UUID>) {
        self.didRestore = didRestore
        self.failedRecordIds = failedRecordIds
    }
}
