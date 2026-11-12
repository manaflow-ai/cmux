public import Foundation

/// Orders a workspace's panel ids from pane order alone, without reading pane geometry.
///
/// ``ExternalTreeNode/orderedPanelIds(paneTabs:fallbackPanelIds:)`` needs a
/// `Bonsplit` tree snapshot, and `BonsplitController.treeSnapshot()` reads the
/// live split container frame to turn normalized bounds into pixel rects. A
/// SwiftUI `body` that builds one therefore observes split-container geometry
/// and re-runs whenever the content area resizes.
///
/// Callers on a render path pass `BonsplitController.allPaneIds` here instead.
/// It walks the same depth-first, first-then-second recursion the tree snapshot
/// reports, so the resulting order is identical, but it touches no frames.
///
/// ```swift
/// SpatialPanelOrder(orderedPaneIds: bonsplitController.allPaneIds.map(\.id.uuidString))
///     .panelIds(paneTabs: paneTabs, fallbackPanelIds: fallbackPanelIds)
/// ```
public struct SpatialPanelOrder {
    private let orderedPaneIds: [String]

    /// Creates an order over panes already listed in on-screen order.
    /// - Parameter orderedPaneIds: Pane identifier strings, first/top pane first.
    public init(orderedPaneIds: [String]) {
        self.orderedPaneIds = orderedPaneIds
    }

    /// Panel ids in on-screen spatial order.
    ///
    /// Panes appear in the order given to ``init(orderedPaneIds:)``, tabs within
    /// each pane in tab order, then any panels missing from the tree in the
    /// caller-provided stable fallback order. Repeated panel ids are dropped
    /// after their first appearance.
    /// - Parameters:
    ///   - paneTabs: Panel ids per pane identifier, in that pane's tab order.
    ///   - fallbackPanelIds: Stable order for panels that no pane lists.
    /// - Returns: The deduplicated panel ids in display order.
    public func panelIds(
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
