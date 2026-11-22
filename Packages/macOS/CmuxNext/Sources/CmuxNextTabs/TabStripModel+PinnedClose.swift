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
    /// `closesPinned` (`tabs.cmdWClosesPinnedTabs`) turns the rule off.
    public func keyboardClose(_ id: TabID, closesPinned: Bool = false) -> TabKeyboardClose {
        guard !closesPinned else { return .close }
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }), ordered[index].isPinned else { return .close }
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        func visible(_ tab: TabItem) -> Bool { tab.groupID.map { !collapsed.contains($0) } ?? true }
        if let next = ordered[(index + 1)...].first(where: visible) { return .select(next.id) }
        if let previous = ordered[..<index].last(where: visible) { return .select(previous.id) }
        return .keep
    }
}
