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
    public func orderedPanelIds(
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }
}
