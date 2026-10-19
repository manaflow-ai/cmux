/// What the user's Cmd-W does to a tab (PINNED-ITEMS-END-TO-END P3).
public enum TabKeyboardClose: Hashable, Sendable {
    /// Close the tab (an unpinned tab).
    case close
    /// Keep the pinned tab and select this tab instead.
    case select(TabID)
    /// Keep the pinned tab: nothing else to select.
    case keep
}

extension TabStripModel {
    /// Chrome-parity rule for a pinned tab: Cmd-W keeps it and selects the
    /// next visible tab in strip order (the previous one when it is last);
    /// only an explicit close (the tab menu, the CLI or MCP by id) closes it.
    /// `closesPinned` (`tabs.cmdWClosesPinnedTabs`) turns the rule off. A tab that
    /// cannot close (``TabItem/isClosable`` false: Home's tab) always follows the rule.
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
        return .keep
    }
}
