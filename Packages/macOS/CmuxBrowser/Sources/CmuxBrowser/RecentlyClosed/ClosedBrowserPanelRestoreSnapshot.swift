public import Foundation
public import Bonsplit

/// The full restore payload a recently-closed browser panel needs to be
/// reopened: its origin workspace, the page it showed, and where it sat in the
/// split layout so it can be put back in the same place.
public struct ClosedBrowserPanelRestoreSnapshot: BrowserPanelRestoreSnapshot {
    /// The workspace that owned the closed browser panel.
    public let workspaceId: UUID
    /// The page the panel was showing, if any.
    public let url: URL?
    /// The browser profile the panel used, if any.
    public let profileID: UUID?
    /// The pane that originally hosted the panel.
    public let originalPaneId: UUID
    /// The tab index the panel occupied within its pane.
    public let originalTabIndex: Int
    /// The split orientation to recreate when the original pane is gone.
    public let fallbackSplitOrientation: SplitOrientation?
    /// Whether the recreated split should insert the panel before the anchor.
    public let fallbackSplitInsertFirst: Bool
    /// The pane to split against when recreating the panel's placement.
    public let fallbackAnchorPaneId: UUID?
    /// When the panel was closed.
    public let closedAt: Date

    /// Creates a restore snapshot for a closed browser panel.
    /// - Parameters:
    ///   - workspaceId: The workspace that owned the closed browser panel.
    ///   - url: The page the panel was showing, if any.
    ///   - profileID: The browser profile the panel used, if any.
    ///   - originalPaneId: The pane that originally hosted the panel.
    ///   - originalTabIndex: The tab index the panel occupied within its pane.
    ///   - fallbackSplitOrientation: The split orientation to recreate when the
    ///     original pane is gone.
    ///   - fallbackSplitInsertFirst: Whether the recreated split should insert
    ///     the panel before the anchor.
    ///   - fallbackAnchorPaneId: The pane to split against when recreating the
    ///     panel's placement.
    ///   - closedAt: When the panel was closed. Defaults to the current time.
    public init(
        workspaceId: UUID,
        url: URL?,
        profileID: UUID?,
        originalPaneId: UUID,
        originalTabIndex: Int,
        fallbackSplitOrientation: SplitOrientation?,
        fallbackSplitInsertFirst: Bool,
        fallbackAnchorPaneId: UUID?,
        closedAt: Date = Date()
    ) {
        self.workspaceId = workspaceId
        self.url = url
        self.profileID = profileID
        self.originalPaneId = originalPaneId
        self.originalTabIndex = originalTabIndex
        self.fallbackSplitOrientation = fallbackSplitOrientation
        self.fallbackSplitInsertFirst = fallbackSplitInsertFirst
        self.fallbackAnchorPaneId = fallbackAnchorPaneId
        self.closedAt = closedAt
    }
}
