public import Foundation
public import Bonsplit

extension ExternalTreeNode {
    /// Pane ids in on-screen spatial order: depth-first over the split tree,
    /// first/top child before second/bottom child. Formerly
    /// `SidebarBranchOrdering.orderedPaneIds(tree:)`.
    public var orderedPaneIds: [String] {
        switch self {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return split.first.orderedPaneIds + split.second.orderedPaneIds
        }
    }

    /// Panel ids in on-screen spatial order: panes in `orderedPaneIds`
    /// order, tabs within each pane in tab order, then any panels missing
    /// from the tree in the caller-provided stable fallback order. Formerly
    /// `SidebarBranchOrdering.orderedPanelIds(tree:paneTabs:fallbackPanelIds:)`.
    /// Building the ``ExternalTreeNode`` this reads costs a live container-frame
    /// read, so a SwiftUI `body` should use ``SpatialPanelOrder`` directly.
    public func orderedPanelIds(
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        SpatialPanelOrder(orderedPaneIds: orderedPaneIds)
            .panelIds(paneTabs: paneTabs, fallbackPanelIds: fallbackPanelIds)
    }
}
