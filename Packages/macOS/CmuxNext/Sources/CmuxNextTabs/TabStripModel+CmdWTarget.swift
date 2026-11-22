import CmuxNextDesignTokens

extension TabStripModel {
    /// The tab a person's Cmd-W on `id` closes: `id`, or while `id`'s close is still under way (`closing`: the daemon's
    /// read, or its page deciding), the tab selected once it closes (the one close-selection rule, ``TabStripModel/closeSuccessor``,
    /// over the tabs not closing: a tab of its opener family, else the next visible one, the one before only at the end), so N quick presses close N tabs
    /// (Leo 2026-10-21), each the one the close before it selected. Nil when every other tab is closing too, or when the
    /// tab that close selects cannot close or is `skipped` (its question shows): the press then closes nothing.
    public func cmdWTarget(_ id: TabID, closing: (TabID) -> Bool, skipped: (TabID) -> Bool = { _ in false }) -> TabID? {
        guard closing(id) else { return id }
        let ordered = orderedTabs
        guard ordered.contains(where: { $0.id == id }) else { return id }
        // The rule runs over every tab that survives, as the close's own selection does (a tab that cannot close, or
        // whose question shows, is still selected after it); a pick the press may not close closes nothing.
        let surviving = ordered.filter { !closing($0.id) }
        let shown = Set(visibleOrderedTabs.map(\.id)).intersection(surviving.map(\.id))
        guard let pick = successor(of: id, old: ordered.map(\.id), surviving: surviving.map(\.id), shown: shown),
              let tab = surviving.first(where: { $0.id == pick }), tab.isClosable, !skipped(pick) else { return nil }
        return pick
    }
}
