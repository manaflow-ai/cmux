public import Foundation

/// Per-panel registry of the last captured ``PanelSnapshotState``, keyed by the
/// terminal surface's `UUID`, backing the debug `panel_snapshot` /
/// `panel_snapshot_reset` commands.
///
/// The store replaces a process-wide `static` dictionary guarded by an
/// `NSLock`. Every caller already runs on the main actor (the snapshot capture
/// path walks AppKit/terminal state), so confining the registry to `@MainActor`
/// supplies the same serialization the lock did and the lock is dropped.
@MainActor
public final class PanelSnapshotStore {
    private var snapshots: [UUID: PanelSnapshotState] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Records `current` as the latest snapshot for `panelId` and returns the
    /// number of pixels that changed versus the previously stored snapshot, or
    /// `-1` when there is no prior snapshot (or its dimensions differ).
    @discardableResult
    public func record(_ current: PanelSnapshotState, for panelId: UUID) -> Int {
        var changedPixels = -1
        if let previous = snapshots[panelId] {
            changedPixels = current.changedPixelCount(comparedTo: previous)
        }
        snapshots[panelId] = current
        return changedPixels
    }

    /// Drops any stored snapshot for `panelId`, so the next `record` reports it
    /// as fresh (`-1`).
    public func reset(_ panelId: UUID) {
        snapshots.removeValue(forKey: panelId)
    }
}
