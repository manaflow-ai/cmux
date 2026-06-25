public import Foundation
public import Bonsplit

/// Where to recreate the pane a closed panel lived in when neither its original
/// pane nor its anchor pane still exists, captured at close time from the live
/// split tree's browser-close fallback plan.
///
/// This is the single owner of the type; the app target reuses it as
/// `typealias ClosedPanelSplitPlacement = CmuxWorkspaces.ClosedPanelSplitPlacement`.
/// A pure `Codable`, `Sendable` value carrying the split `orientation`, whether the
/// new pane is inserted as the split's first (left/top) branch, and the panel id of
/// the surviving anchor the split is grown from. The
/// ``ClosedPanelHistoryCoordinator`` reads these to drive the app-side fallback
/// split during a restore.
public struct ClosedPanelSplitPlacement: Codable, Sendable {
    /// The orientation of the split the recreated pane joins.
    public let orientation: SplitOrientation
    /// Whether the recreated pane is the split's first (left/top) branch.
    public let insertFirst: Bool
    /// The panel id of the surviving anchor the fallback split is grown beside,
    /// or `nil` when no anchor could be resolved.
    public let anchorPanelId: UUID?

    /// Creates a closed-panel fallback split placement.
    public init(orientation: SplitOrientation, insertFirst: Bool, anchorPanelId: UUID?) {
        self.orientation = orientation
        self.insertFirst = insertFirst
        self.anchorPanelId = anchorPanelId
    }
}
