/// What the user's Cmd-W does to a tab (PINNED-ITEMS-END-TO-END P3).
public enum TabKeyboardClose: Hashable, Sendable {
    /// Close the tab (an unpinned tab).
    case close
    /// Keep the pinned tab and select this tab instead.
    case select(TabID)
    /// Keep the pinned tab: nothing else to select.
    case keep
    /// Do nothing and say nothing: a tab that cannot close (Home's tab) with nothing else to
    /// select. Cmd-W in the Home Chief pane is not an error (plans/cmux-next/home-chief-pane.md).
    case ignore
}

extension TabStripModel {
    /// What Cmd-W does to `id`. A pinned tab closes when `closesPinned`
    /// (`tabs.cmdWClosesPinnedTabs`, on by default, as Chrome's Cmd-W closes a
    /// pinned tab); with it off, Cmd-W keeps a pinned tab and selects the next
    /// visible tab in strip order (the previous one when it is last), and only an
    /// explicit close (the tab menu, the CLI or MCP by id) closes it. A tab that
    /// cannot close (``TabItem/isClosable`` false: Home's tab) is always kept.
    public func keyboardClose(_ id: TabID, closesPinned: Bool = false) -> TabKeyboardClose {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return .close }
        // A tab that cannot close (Home's tab, `pinned-dock-v1`) is kept like a pinned one,
        // whatever `closesPinned` says.
        let keeps = !ordered[index].isClosable || (ordered[index].isPinned && !closesPinned)
        guard keeps else { return .close }
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        func visible(_ tab: TabItem) -> Bool { tab.groupID.map { !collapsed.contains($0) } ?? true }
        if let next = ordered[(index + 1)...].first(where: visible) { return .select(next.id) }
        if let previous = ordered[..<index].last(where: visible) { return .select(previous.id) }
        return ordered[index].isClosable ? .keep : .ignore
    }
}

extension TabStripModel {
    // Chrome's close commands (`TabStripModel::GetTabsClosedByCommand`): Close Other Tabs and
    // Close Tabs to the Right (and cmux's Close Tabs to the Left) never close a pinned tab. Only
    // Close Tab, the CLI or MCP naming the tab (and Cmd-W, with `tabs.cmdWClosesPinnedTabs` on) closes a pinned tab.
    // None of them lists a tab that cannot close (Home's tab, `pinned-dock-v1`).

    /// The tabs Close Other Tabs closes for `keep`, in strip order: every other unpinned tab.
    public func closedByCloseOthers(keeping keep: TabID) -> [TabID] {
        orderedTabs.filter { $0.id != keep && !$0.isPinned && $0.isClosable }.map(\.id)
    }

    /// The tabs Close Tabs to the Right closes for `id`, in strip order: the unpinned tabs after it.
    public func closedByCloseToRight(of id: TabID) -> [TabID] {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        return ordered[(index + 1)...].filter { !$0.isPinned && $0.isClosable }.map(\.id)
    }

    /// The tabs Close Tabs to the Left closes for `id`, in strip order: the unpinned tabs before it.
    public func closedByCloseToLeft(of id: TabID) -> [TabID] {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        return ordered[..<index].filter { !$0.isPinned && $0.isClosable }.map(\.id)
    }
}

extension TabStripModel {
    /// Where Move Tab Left (`offset` -1) or Move Tab Right (+1) takes `id`, as a display index;
    /// nil at the edge of its section. A pinned tab moves only among the pinned tabs and an
    /// unpinned one only among the rest, as in Chrome. A group's members stay together
    /// (`TabGroupOrdering.normalized`), so a tab outside a group steps past the whole group, and a
    /// member moves only among its group's members.
    public func moveIndex(of id: TabID, by offset: Int) -> Int? {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }), offset != 0 else { return nil }
        let pinnedCount = ordered.count(where: \.isPinned)
        var section = ordered[index].isPinned ? 0..<pinnedCount : pinnedCount..<ordered.count
        let group = ordered[index].groupID
        if let group, let first = ordered.firstIndex(where: { $0.groupID == group }),
           let last = ordered.lastIndex(where: { $0.groupID == group }) {
            section = first..<(last + 1)
        }
        var target = index + offset
        guard section.contains(target) else { return nil }
        // Beside another group: past all of it (one step inside would be undone by the ordering).
        if group == nil, let neighbor = ordered[target].groupID {
            target = offset < 0 ? ordered.firstIndex { $0.groupID == neighbor } ?? target
                : ordered.lastIndex { $0.groupID == neighbor } ?? target
        }
        return target
    }
}

extension TabStripModel {
    /// The tabs the strip shows, in strip order: every tab but the members
    /// of a collapsed group (Chrome's next and previous tab skip them too).
    public var visibleOrderedTabs: [TabItem] {
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        return orderedTabs.filter { tab in tab.groupID.map { !collapsed.contains($0) } ?? true }
    }

    /// The visible tab `offset` steps from `id` in strip order, wrapping
    /// (Next / Previous Tab). From a hidden tab it counts from its place.
    public func adjacentVisibleTab(from id: TabID?, offset: Int) -> TabID? {
        let ordered = orderedTabs
        let visible = Set(visibleOrderedTabs.map(\.id))
        guard !visible.isEmpty, offset != 0 else { return nil }
        let count = ordered.count
        var index = id.flatMap { id in ordered.firstIndex { $0.id == id } } ?? (offset > 0 ? count - 1 : 0)
        var remaining = abs(offset)
        let step = offset > 0 ? 1 : -1
        while remaining > 0 {
            index = (index + step + count) % count
            if visible.contains(ordered[index].id) { remaining -= 1 }
        }
        return ordered[index].id
    }
}
