nonisolated extension CloseSelection {
    /// The tab a pane selects after `selected` closed, by the one close-selection rule
    /// (plans/cmux-next/close-focus.md, "One close-selection rule"): a tab it opened, a tab its opener
    /// opened, its opener, its group's next tab (else the one before it in the group), else the NEXT
    /// shown tab, and the previous one only when it was the last (Chromium's `DetermineNewSelectedIndex`).
    /// `old` is the strip before the close, `surviving` the tabs left, `shown` the surviving tabs a
    /// collapsed group does not hide, `groups` each grouped tab's group (the closed tab's too). A
    /// `selected` that survives stays. Call it before `left` for the closed tabs. A new instance holds
    /// no relation: its pick is by position and group.
    public func successor(ofTab selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>, groups: [ID: String] = [:]) -> ID? {
        tab(selected: selected, old: old, surviving: surviving, shown: shown, groups: groups)
    }
}
