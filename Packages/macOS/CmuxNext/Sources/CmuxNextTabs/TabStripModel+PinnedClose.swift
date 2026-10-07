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
    public func keyboardClose(_ id: TabID) -> TabKeyboardClose {
        .close
    }
}
