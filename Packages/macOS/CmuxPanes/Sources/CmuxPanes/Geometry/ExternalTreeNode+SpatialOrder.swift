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

    /// Folds the layout *shape* into `hasher`: the split nesting and
    /// orientation, the surface (tab) order within each pane, the selected
    /// surface per pane, and divider positions (rounded to 0.1% so sub-pixel
    /// jitter does not churn). This mirrors exactly the fields the session
    /// snapshot persists for the layout, so the value changes if and only if a
    /// restore would bring the panes back differently.
    ///
    /// Frames are deliberately excluded: they are recomputed on restore (only
    /// the divider *fractions* are persisted) and would otherwise change on
    /// every window resize.
    ///
    /// The session autosave fingerprint folds this in so reordering or
    /// resplitting panes — which leaves the panel *set* unchanged — still bumps
    /// the fingerprint and triggers a save. Without it the 8s autosave timer
    /// skips the write and a non-graceful exit restores a stale pane layout
    /// (https://github.com/manaflow-ai/cmux/issues/6184).
    public func combineLayoutFingerprint(into hasher: inout Hasher) {
        switch self {
        case .pane(let pane):
            hasher.combine(0)
            hasher.combine(pane.tabs.count)
            for tab in pane.tabs {
                hasher.combine(tab.id)
            }
            hasher.combine(pane.selectedTabId)
        case .split(let split):
            hasher.combine(1)
            hasher.combine(split.orientation)
            // dividerPosition is a 0.0...1.0 fraction; round to 0.1% so it is
            // stable under sub-pixel jitter but still reflects real resizes.
            hasher.combine(Int((split.dividerPosition * 1000).rounded()))
            split.first.combineLayoutFingerprint(into: &hasher)
            split.second.combineLayoutFingerprint(into: &hasher)
        }
    }
}
