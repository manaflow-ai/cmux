public import Foundation

/// The panel limit a session snapshot applies to one workspace or one Dock.
///
/// Snapshot construction keeps the first ``maxPanels`` panel ids in order and
/// counts the rest, so the snapshot can record how many panels it left out.
/// Restore cannot bring omitted panels back; the count lets it say so.
///
/// ```swift
/// let result = SessionPanelCap().cap(orderedPanelIds)
/// let kept = result.retainedPanelIds
/// let omittedPanelCount = result.omittedCount > 0 ? result.omittedCount : nil
/// ```
public struct SessionPanelCap: Equatable, Sendable {
    /// Panels kept for one workspace and for one Dock in a session snapshot.
    ///
    /// The bound keeps a session file from growing without limit. It is
    /// documented in `docs/session-snapshots.md`.
    public static let sessionSnapshotMaxPanels = 512

    /// The most panel ids ``cap(_:)`` retains. Never negative.
    public let maxPanels: Int

    /// Creates a cap.
    ///
    /// - Parameter maxPanels: The most panel ids to retain. Defaults to
    ///   ``sessionSnapshotMaxPanels``, the session snapshot policy. Negative
    ///   values are treated as zero.
    public init(maxPanels: Int = SessionPanelCap.sessionSnapshotMaxPanels) {
        self.maxPanels = max(0, maxPanels)
    }

    /// Splits `panelIds` into the prefix a snapshot keeps and a count of the
    /// ids past ``maxPanels``.
    ///
    /// Order is preserved and the input is read once.
    ///
    /// - Parameter panelIds: Panel ids in snapshot order.
    /// - Returns: The retained prefix and the number of ids left out, which is
    ///   zero when every id fits.
    public func cap<S: Sequence>(_ panelIds: S) -> SessionPanelCapResult where S.Element == UUID {
        var retainedPanelIds: [UUID] = []
        retainedPanelIds.reserveCapacity(Swift.min(maxPanels, panelIds.underestimatedCount))
        var omittedCount = 0
        for panelId in panelIds {
            if retainedPanelIds.count < maxPanels {
                retainedPanelIds.append(panelId)
            } else {
                omittedCount += 1
            }
        }
        return SessionPanelCapResult(retainedPanelIds: retainedPanelIds, omittedCount: omittedCount)
    }
}
