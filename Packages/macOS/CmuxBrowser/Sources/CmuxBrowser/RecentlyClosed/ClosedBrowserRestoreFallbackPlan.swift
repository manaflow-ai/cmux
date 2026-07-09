public import Foundation
public import Bonsplit

/// The browser-close fallback placement, mirrored as a package-local Sendable
/// value so ``ClosedBrowserRestoreStaging`` can read the `CmuxPanes`
/// `browserCloseFallbackPlan` result without `CmuxBrowser` depending on
/// `CmuxPanes`. The app-target host builds this from the Bonsplit tree
/// snapshot's fallback plan.
public struct ClosedBrowserRestoreFallbackPlan: Sendable {
    /// The split orientation to recreate when the original pane is gone.
    public let orientation: SplitOrientation
    /// Whether the recreated split should insert the panel before the anchor.
    public let insertFirst: Bool
    /// The pane to split against when recreating the panel's placement.
    public let anchorPaneId: UUID?

    /// Creates a fallback placement.
    /// - Parameters:
    ///   - orientation: The split orientation to recreate.
    ///   - insertFirst: Whether to insert the panel before the anchor.
    ///   - anchorPaneId: The pane to split against, if any.
    public init(orientation: SplitOrientation, insertFirst: Bool, anchorPaneId: UUID?) {
        self.orientation = orientation
        self.insertFirst = insertFirst
        self.anchorPaneId = anchorPaneId
    }
}
