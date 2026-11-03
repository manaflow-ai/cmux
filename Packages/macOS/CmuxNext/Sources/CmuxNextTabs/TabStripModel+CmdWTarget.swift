extension TabStripModel {
    /// The tab a person's Cmd-W on `id` closes: `id`, or while `id`'s close is still under way (`closing`: the daemon's
    /// read, or its page deciding), the tab selected once it closes (the next closable tab neither closing nor `skipped`,
    /// else the previous), so N quick presses close N tabs (Leo 2026-10-21). Nil when every other tab is closing too.
    public func cmdWTarget(_ id: TabID, closing: (TabID) -> Bool, skipped: (TabID) -> Bool = { _ in false }) -> TabID? {
        guard closing(id) else { return id }
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return id }
        func open(_ tab: TabItem) -> Bool { !closing(tab.id) && !skipped(tab.id) && tab.isClosable }
        return (ordered[(index + 1)...].first(where: open) ?? ordered[..<index].last(where: open))?.id
    }
}
