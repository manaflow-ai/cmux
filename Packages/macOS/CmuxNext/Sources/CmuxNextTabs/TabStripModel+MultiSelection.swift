// What the strip's multi-selection (`TabMultiSelection`) means for the model's tabs and actions:
// the menu and Cmd-W act on every selected tab, and the selection follows tabs that close or an
// active tab that changes from elsewhere.
extension TabStripModel {
    /// A click on `id` with `click`'s modifiers. Returns the tab to make active (send `.select`),
    /// nil when the active tab stays. A strip without multi-selection takes every click as plain.
    public func click(_ id: TabID, _ click: TabMultiSelection.Click) -> TabID? {
        var selection = multiSelection
        let next = selection.click(id, allowsMultiSelection ? click : .plain, order: orderedTabs.map(\.id), active: selectedID)
        if selection != multiSelection { multiSelection = selection }
        return next
    }

    /// Back to the active tab alone (a plain click, Esc).
    public func clearMultiSelection() {
        if !multiSelection.ids.isEmpty { multiSelection.clear() }
    }

    /// The selected tabs in display order; the active tab alone while only it is selected.
    public var selectedTabIDs: [TabID] {
        multiSelection.ordered(in: orderedTabs.map(\.id), active: selectedID)
    }

    /// The tabs an action on `id` applies to: every selected tab, in display order, when `id` is
    /// one of several selected tabs; else `id` alone (Chrome's tab menu on a tab outside the
    /// selection acts on that tab).
    public func actingTabs(for id: TabID) -> [TabID] {
        multiSelection.isMultiple && multiSelection.contains(id) ? selectedTabIDs : [id]
    }

    /// `TabContextTarget.tab`'s selection for a right-click on `id`: the clicked tab first.
    public func contextSelection(for id: TabID) -> [TabID] {
        [id] + actingTabs(for: id).filter { $0 != id }
    }

    /// The tabs Close Other Tabs closes when `keep` (a selection) stays: every unpinned tab outside it.
    public func closedByCloseOthers(keepingAll keep: [TabID]) -> [TabID] {
        let kept = Set(keep)
        return orderedTabs.filter { !kept.contains($0.id) && !$0.isPinned }.map(\.id)
    }

    /// Pin for `ids` pins them all unless every one is pinned already, which unpins them (Chrome's
    /// Pin Tabs / Unpin Tabs).
    public func pinsAll(_ ids: [TabID]) -> Bool {
        let wanted = Set(ids)
        return tabs.contains { wanted.contains($0.id) && !$0.isPinned }
    }

    /// Cmd-W's tabs while several are selected and `id` (the active tab) is one of them: the
    /// selected tabs that Cmd-W closes on their own (``keyboardClose(_:closesPinned:)``), in
    /// display order. Nil without a selection, or when it closes none of them (every one is pinned):
    /// the one-tab rule applies then.
    public func keyboardCloseSelection(_ id: TabID, closesPinned: Bool) -> [TabID]? {
        guard multiSelection.isMultiple, multiSelection.contains(id) else { return nil }
        let closed = selectedTabIDs.filter { tab in
            guard let item = self.tab(tab) else { return false }
            return item.isClosable && (!item.isPinned || closesPinned)
        }
        return closed.isEmpty ? nil : closed
    }

    /// The order after the selection is moved to `index` (counted without the selected tabs), as a
    /// multi-tab drag drops it.
    public func orderMovingSelection(to index: Int) -> [TabID] {
        TabSelectionMove(orderedTabs).moving(multiSelection.ids, to: index)
    }

    func followTabs() {
        guard !multiSelection.ids.isEmpty || multiSelection.anchor != nil else { return }
        var selection = multiSelection
        selection.follow(order: tabs.map(\.id))
        if selection != multiSelection { multiSelection = selection }
    }

    func followActive() {
        guard !multiSelection.ids.isEmpty else { return }
        var selection = multiSelection
        selection.activated(selectedID)
        if selection != multiSelection { multiSelection = selection }
    }
}
