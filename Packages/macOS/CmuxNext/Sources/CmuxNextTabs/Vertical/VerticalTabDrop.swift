/// What dropping a dragged tab on a slot of the vertical tab list asks the App to do
/// (`VerticalTabListLayout.Slot`). Indices are positions in `tabs` (`TabStripModel.orderedTabs`).
/// - A drop in the tab's own group (or outside groups, for an ungrouped tab) is `.reorder`.
/// - A drop in another group is `.addToGroup`; a grouped tab dropped outside every group is
///   `.removeFromGroup`.
/// - Pinned tabs stay among the pinned tabs, and other tabs after them.
/// - A drag of one of several selected tabs in a list with no groups moves them all
///   (`.reorderTabs`, Chrome's `MoveSelectedTabsTo`), as the strip does.
public struct VerticalTabDrop: Equatable {
    public var tabs: [TabItem]
    public var selection: TabMultiSelection
    /// The strip has groups: a drag moves its one tab (a group keeps its members together, so a
    /// multi-tab drop into or out of one would ask for an order the list can never show).
    public var hasGroups: Bool

    public init(tabs: [TabItem], selection: TabMultiSelection = TabMultiSelection(), hasGroups: Bool = false) {
        self.tabs = tabs
        self.selection = selection
        self.hasGroups = hasGroups
    }

    /// A drag of `id` moves every selected tab.
    public func movesSelection(_ id: TabID) -> Bool {
        selection.isMultiple && selection.contains(id) && !hasGroups
    }

    /// The intent for dropping `id` before `tabs[index]` (`tabs.count`: at the end) in `group` (nil:
    /// outside every group). Nil when the drop changes nothing.
    public func intent(dropping id: TabID, at index: Int, in group: TabGroupID?) -> TabStripIntent? {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let position = min(max(index, 0), tabs.count)
        if movesSelection(id) {
            let current = tabs.map(\.id)
            let rest = tabs[..<position].filter { !selection.contains($0.id) }.count
            let order = TabSelectionMove(tabs).moving(selection.ids, to: rest)
            return order == current ? nil : .reorderTabs(order)
        }
        let dragged = tabs[from]
        let pinnedCount = tabs.filter(\.isPinned).count
        var final = position > from ? position - 1 : position
        if dragged.isPinned {
            final = min(max(final, 0), max(pinnedCount - 1, 0))
            return final == from ? nil : .reorder(id, from: from, to: final)
        }
        final = min(max(final, pinnedCount), tabs.count - 1)
        if dragged.groupID == group { return final == from ? nil : .reorder(id, from: from, to: final) }
        if let group { return .addToGroup(id, group, index: final) }
        return .removeFromGroup(id, index: final)
    }

    /// The intent for dropping `id` on `slot`.
    public func intent(dropping id: TabID, on slot: VerticalTabListLayout.Slot) -> TabStripIntent? {
        intent(dropping: id, at: slot.index, in: slot.group)
    }
}
