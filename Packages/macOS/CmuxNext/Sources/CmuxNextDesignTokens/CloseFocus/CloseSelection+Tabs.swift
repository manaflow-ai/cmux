nonisolated extension CloseSelection {
    /// The tab a pane selects after `selected` closed, by the one close-selection rule
    /// (plans/cmux-next/close-focus.md, "One close-selection rule"): a tab it opened, a tab its opener
    /// opened, its opener, else the NEXT shown tab, and the previous one only when it was the last.
    /// No group is read (decision 2026-11-10: Chrome as observed selects the next tab across a group's
    /// edge). `old` is the strip before the close, `surviving` the tabs left, `shown` the surviving
    /// tabs a collapsed group does not hide. A `selected` that survives stays. Call it before `left`
    /// for the closed tabs. A new instance holds no relation: its pick is by position.
    public func successor(ofTab selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>) -> ID? {
        tab(selected: selected, old: old, surviving: surviving, shown: shown)
    }
}
