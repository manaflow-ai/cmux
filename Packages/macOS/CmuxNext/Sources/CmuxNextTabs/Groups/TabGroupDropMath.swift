public import CoreGraphics

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

/// Pure drop math for tabs and whole groups over a strip that has groups.
///
/// `entries` are the unpinned layout slots in display order without the
/// dragged item (chips included, the drop gap excluded). Only their widths,
/// group ids, and chip/collapsed flags matter: positions are recomputed from
/// `start`, because the real slots still contain the dragged item's space.
public struct TabGroupDropMath {
    public init() {}
    /// Resolves index and group membership for a tab whose leading edge is
    /// at `draggedMinX`.
    ///
    /// The candidate edge nearest to the leading edge wins. A position
    /// between two members of a group (or right after its chip) is inside it.
    /// A position after a group's last member is ambiguous; the tab stays in
    /// its current membership until its leading edge passes the group edge
    /// by `hysteresis`, so it does not flicker in and out at the boundary.
    /// Positions inside a collapsed group are never chosen.
    public static func resolveTab(
        entries: [TabLayoutSlot],
        start: CGFloat,
        draggedMinX: CGFloat,
        currentGroup: TabGroupID?,
        hysteresis: CGFloat
    ) -> TabGroupDropResolution {
        var bestK = 0
        var bestDistance = CGFloat.infinity
        var bestEdge = start
        var edge = start
        for k in 0...entries.count {
            if isValidPosition(k, entries) {
                let distance = abs(edge - draggedMinX)
                if distance < bestDistance {
                    bestDistance = distance
                    bestK = k
                    bestEdge = edge
                }
            }
            if k < entries.count { edge += entries[k].width }
        }
        let index = entries[..<bestK].count { !$0.isGroupChip }
        let left = bestK > 0 ? entries[bestK - 1] : nil
        let right = bestK < entries.count ? entries[bestK] : nil
        return TabGroupDropResolution(
            index: index,
            groupID: membership(left: left, right: right, offset: draggedMinX - bestEdge, current: currentGroup, hysteresis: hysteresis)
        )
    }

    /// Positions before a collapsed member are inside a collapsed group.
    static func isValidPosition(_ k: Int, _ entries: [TabLayoutSlot]) -> Bool {
        guard k < entries.count else { return true }
        return !entries[k].isCollapsed
    }

    static func membership(
        left: TabLayoutSlot?,
        right: TabLayoutSlot?,
        offset: CGFloat,
        current: TabGroupID?,
        hysteresis: CGFloat
    ) -> TabGroupID? {
        guard let left, let group = left.groupID else { return nil }
        if left.isGroupChip { return group }
        if left.isCollapsed { return nil }
        if let right, right.groupID == group, !right.isGroupChip { return group }
        // Trailing edge of an expanded group: ambiguous, apply hysteresis.
        let threshold = current == group ? hysteresis : -hysteresis
        return offset < threshold ? group : nil
    }

    /// Movable units: an ungrouped tab, or a chip with all its members.
    public struct Unit: Equatable, Sendable {
        public var width: CGFloat
        public var tabCount: Int
    }

    public static func units(_ entries: [TabLayoutSlot]) -> [Unit] {
        var units: [Unit] = []
        var currentGroup: TabGroupID?
        for entry in entries {
            let tabs = entry.isGroupChip ? 0 : 1
            if let group = entry.groupID, group == currentGroup, !entry.isGroupChip, !units.isEmpty {
                units[units.count - 1].width += entry.width
                units[units.count - 1].tabCount += tabs
            } else {
                units.append(Unit(width: entry.width, tabCount: tabs))
                currentGroup = entry.groupID
            }
        }
        return units
    }

    /// Unit index for a whole group whose leading edge is at `draggedMinX`,
    /// and the matching tab insertion index among the entries' tabs.
    public static func resolveGroup(entries: [TabLayoutSlot], start: CGFloat, draggedMinX: CGFloat) -> (unitIndex: Int, tabIndex: Int) {
        let units = units(entries)
        let unitIndex = TabReorderMath.insertionIndex(draggedMinX: draggedMinX, groupStart: start, otherWidths: units.map(\.width))
        return (unitIndex, units[..<unitIndex].reduce(0) { $0 + $1.tabCount })
    }
}
