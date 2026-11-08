import CmuxNextDesignTokens

extension TabStripModel {
    /// The tab a person's Cmd-W on `id` closes: `id`, or while `id`'s close is still under way (`closing`: the daemon's
    /// read, or its page deciding), the tab selected once it closes (``FocusAfterClose/tab(selected:old:surviving:shown:)``
    /// over the closable tabs neither closing nor `skipped`: the visible one before it, else the one after it), so N quick
    /// presses close N tabs (Leo 2026-10-21), each the one the close before it selected. Nil when every other tab is closing too.
    public func cmdWTarget(_ id: TabID, closing: (TabID) -> Bool, skipped: (TabID) -> Bool = { _ in false }) -> TabID? {
        guard closing(id) else { return id }
        let ordered = orderedTabs
        guard ordered.contains(where: { $0.id == id }) else { return id }
        let open = ordered.filter { !closing($0.id) && !skipped($0.id) && $0.isClosable }.map(\.id)
        let shown = Set(visibleOrderedTabs.map(\.id)).intersection(open)
        return FocusAfterClose.tab(selected: id, old: ordered.map(\.id), surviving: open, shown: shown)
    }
}
