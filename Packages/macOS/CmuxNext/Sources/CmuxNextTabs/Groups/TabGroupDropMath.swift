public import CoreGraphics
import CmuxNextDesignTokens

/// Where a dragged tab lands relative to groups.
public struct TabGroupDropResolution: Equatable, Sendable {
    /// Insertion index among the tabs (chips excluded) of the entries.
    public var index: Int
    /// Group the tab joins at that position, nil for ungrouped.
    public var groupID: TabGroupID?

    public init(index: Int, groupID: TabGroupID?) {
        self.index = index
        self.groupID = groupID
    }
}

/// Drop math for tabs and whole groups over a strip that has groups, asked of
/// Rust (cmux-layout-reducer `drop_rules`, ops `drop_tab_over_groups` and
/// `drop_group_over_groups`, with their table tests).
///
/// `entries` are the unpinned layout slots in display order without the
/// dragged item (chips included, the drop gap excluded). Only their widths,
/// group ids, and chip/collapsed flags matter: positions are recomputed from
/// `start`, because the real slots still contain the dragged item's space.
public struct TabGroupDropMath {
    public init() {}
    /// Index and group membership for a dragged tab probed at `draggedMinX`
    /// (the card's leading edge for a reorder within one strip, the pointer for
    /// a tab dropped from elsewhere). The nearest valid edge wins; a group's
    /// trailing edge keeps the current membership within `hysteresis`;
    /// positions inside a collapsed group are never chosen.
    public static func resolveTab(
        entries: [TabLayoutSlot],
        start: CGFloat,
        draggedMinX: CGFloat,
        currentGroup: TabGroupID?,
        hysteresis: CGFloat
    ) -> TabGroupDropResolution {
        let request = TabDropWire.OverGroups(
            entries: entries, start: start, draggedMinX: draggedMinX, currentGroup: currentGroup, hysteresis: hysteresis
        )
        guard let landing = DropRules.call("drop_tab_over_groups", request, as: TabDropWire.TabLanding.self) else {
            return TabGroupDropResolution(index: 0, groupID: nil)
        }
        return TabGroupDropResolution(index: landing.index, groupID: landing.group.map { TabGroupID($0) })
    }

    /// Unit index for a whole group whose leading edge is at `draggedMinX`,
    /// and the matching tab insertion index among the entries' tabs. A unit is
    /// an ungrouped tab, or a chip with all its members.
    public static func resolveGroup(entries: [TabLayoutSlot], start: CGFloat, draggedMinX: CGFloat) -> (unitIndex: Int, tabIndex: Int) {
        let request = TabDropWire.OverGroups(entries: entries, start: start, draggedMinX: draggedMinX, currentGroup: nil, hysteresis: 0)
        guard let landing = DropRules.call("drop_group_over_groups", request, as: TabDropWire.GroupLanding.self) else { return (0, 0) }
        return (landing.unitIndex, landing.tabIndex)
    }
}
