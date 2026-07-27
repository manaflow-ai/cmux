public import Foundation

/// Persistence seam for the app session snapshot (save/restore of the whole
/// window/workspace tree across launches).
///
/// `AppDelegate` drives this seam: startup restore, the autosave queue, the
/// synchronous save on termination, and the manual "Reopen Previous Session"
/// flow. The production conformer is ``SessionSnapshotRepository``.
public protocol SessionSnapshotStoring<SnapshotValue>: Sendable {
    /// The app-owned snapshot root type this store persists.
    associatedtype SnapshotValue: SessionSnapshotRepresenting

    /// Inspects the snapshot file at `fileURL` without side effects.
    func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<SnapshotValue>

    /// Loads a usable snapshot from `fileURL`, or from the default snapshot
    /// location when `fileURL` is nil. Returns nil for missing or unusable
    /// snapshots.
    func load(fileURL: URL?) -> SnapshotValue?

    /// Writes `snapshot` to `fileURL` (default snapshot location when nil),
    /// creating intermediate directories. Skips the write when the encoded
    /// bytes equal the file's current contents. Returns false on any failure.
    @discardableResult
    func save(_ snapshot: SnapshotValue, fileURL: URL?) -> Bool

    /// Removes the snapshot file at `fileURL` (default snapshot location
    /// when nil), ignoring errors.
    func removeSnapshot(fileURL: URL?)

    /// Loads the manual-restore ("Reopen Previous Session") snapshot from
    /// `fileURL`, or from the backup snapshot location when nil.
    func loadReopenSessionSnapshot(fileURL: URL?) -> SnapshotValue?

    /// Mirrors the primary snapshot into the manual-restore backup: a usable
    /// primary is copied, a missing primary removes the backup, and an
    /// unusable primary leaves the backup in place as the only remaining
    /// recovery path.
    func syncManualRestoreSnapshotCache()

    /// Loads the startup snapshot: the primary when usable, otherwise the
    /// manual-restore backup when the primary exists but cannot be restored.
    func loadStartupSnapshot() -> SnapshotValue?

    /// Location of the primary snapshot file, or nil when Application
    /// Support cannot be resolved.
    func defaultSnapshotFileURL() -> URL?

    /// Location of the manual-restore backup snapshot file, or nil when
    /// Application Support cannot be resolved.
    func manualRestoreSnapshotFileURL() -> URL?
}
