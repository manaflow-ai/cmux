public import Foundation

/// A Sendable snapshot of the selected workspace's bonsplit panes for the v1
/// `list_panes` listing.
public struct ControlSidebarPaneListSnapshot: Sendable, Equatable {
    /// Pane ids in layout order.
    public let paneIDs: [UUID]
    /// The focused pane id, if any.
    public let focusedPaneID: UUID?
    /// The bonsplit tab count of each pane, aligned with ``paneIDs``.
    public let tabCounts: [Int]

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - paneIDs: Pane ids in layout order.
    ///   - focusedPaneID: The focused pane id, if any.
    ///   - tabCounts: The bonsplit tab count of each pane.
    public init(paneIDs: [UUID], focusedPaneID: UUID?, tabCounts: [Int]) {
        self.paneIDs = paneIDs
        self.focusedPaneID = focusedPaneID
        self.tabCounts = tabCounts
    }
}
