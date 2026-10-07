public import CmuxNextDesign
public import CoreGraphics

/// Pure rules for groups, shared by every strip that groups items (pane
/// tab strips and the screen bar): pinned items first and never grouped,
/// group members contiguous, one chip before each group's members, the
/// selection leaving a collapsing group, and the color a new group gets.
public struct TabGroupOrdering {
    public init() {}
    /// Pinned tabs first (group cleared), then unpinned tabs in order with
    /// each group's members moved up to its first member. Tabs that name a
    /// group not in `groups` become ungrouped.
    public static func normalized(_ tabs: [TabItem], groups: Set<TabGroupID>) -> [TabItem] {
        var pinned: [TabItem] = []
        var units: [[TabItem]] = []
        var unitOfGroup: [TabGroupID: Int] = [:]
        for var tab in tabs {
            if tab.isPinned || tab.groupID.map({ !groups.contains($0) }) == true { tab.groupID = nil }
            if tab.isPinned {
                pinned.append(tab)
            } else if let group = tab.groupID, let unit = unitOfGroup[group] {
                units[unit].append(tab)
            } else {
                if let group = tab.groupID { unitOfGroup[group] = units.count }
                units.append([tab])
            }
        }
        return pinned + units.flatMap(\.self)
    }

    /// Layout items for tabs in display order, with a chip before each
    /// group's first member. Members of collapsed groups are marked
    /// collapsed; `chipWidths` supplies each chip's measured width.
    public static func layoutItems(
        _ tabs: [TabItem],
        groups: [TabGroupID: TabGroupItem],
        selectedID: TabID?,
        chipWidths: [TabGroupID: CGFloat]
    ) -> [TabLayoutItem] {
        var items: [TabLayoutItem] = []
        items.reserveCapacity(tabs.count + groups.count)
        var previousGroup: TabGroupID?
        var seen: Set<TabGroupID> = []
        for tab in tabs {
            let group = tab.isPinned ? nil : tab.groupID.flatMap { groups[$0] }
            if let group, group.id != previousGroup, seen.insert(group.id).inserted {
                items.append(TabLayoutItem(
                    id: .groupChip(group.id),
                    groupID: group.id,
                    fixedWidth: chipWidths[group.id] ?? 0,
                    isGroupChip: true
                ))
            }
            items.append(TabLayoutItem(
                id: tab.id,
                isPinned: tab.isPinned,
                isSelected: tab.id == selectedID,
                groupID: group?.id,
                isCollapsed: group?.isCollapsed ?? false
            ))
            previousGroup = group?.id
        }
        return items
    }

    /// The item to select before `group` collapses over `selected`, for
    /// callers that cannot open a new item: the nearest visible item
    /// (`selectionAfterCollapsing`), else the first item outside the group
    /// (selecting it expands its own collapsed group, so the selection stays
    /// visible). Nil when nothing needs to change or every item is in `group`.
    public static func selectionBeforeCollapsing(
        _ group: TabGroupID,
        in ordered: [TabItem],
        collapsed: Set<TabGroupID>,
        selected: TabID?
    ) -> TabID? {
        guard let selected, ordered.first(where: { $0.id == selected })?.groupID == group else { return nil }
        return selectionAfterCollapsing(group, in: ordered, collapsed: collapsed, selected: selected)
            ?? ordered.first { $0.groupID != group }?.id
    }

    /// The color a new group gets: the first of the nine group colors no
    /// group in the same strip uses yet, skipping blue (no blue in
    /// what cmux picks itself; a user may still choose it); grey when every
    /// color is taken.
    public static func nextColor(used: some Sequence<GroupColor>) -> GroupColor {
        let taken = Set(used)
        return GroupColor.allCases.first { $0 != .blue && !taken.contains($0) } ?? .grey
    }

    /// When a group collapses over the selection: select the
    /// nearest tab to the right outside the group, else to the left. Nil
    /// when every visible tab is in the group (the caller opens a new tab).
    public static func selectionAfterCollapsing(
        _ group: TabGroupID,
        in ordered: [TabItem],
        collapsed: Set<TabGroupID>,
        selected: TabID?
    ) -> TabID? {
        guard let selected, let index = ordered.firstIndex(where: { $0.id == selected }) else { return selected }
        guard ordered[index].groupID == group else { return selected }
        func visible(_ tab: TabItem) -> Bool {
            guard let other = tab.groupID else { return true }
            return other != group && !collapsed.contains(other)
        }
        if let right = ordered[(index + 1)...].first(where: visible) { return right.id }
        if let left = ordered[..<index].last(where: visible) { return left.id }
        return nil
    }
}
