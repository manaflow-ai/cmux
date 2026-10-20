// Multi-selection actions. Not built yet: every action acts on the one tab.
extension TabStripModel {
    public func click(_ id: TabID, _ click: TabMultiSelection.Click) -> TabID? { id }
    public func clearMultiSelection() {}
    public var selectedTabIDs: [TabID] { selectedID.map { [$0] } ?? [] }
    public func actingTabs(for id: TabID) -> [TabID] { [id] }
    public func contextSelection(for id: TabID) -> [TabID] { [id] }
    public func closedByCloseOthers(keepingAll keep: [TabID]) -> [TabID] { [] }
    public func pinsAll(_ ids: [TabID]) -> Bool { false }
    public func keyboardCloseSelection(_ id: TabID, closesPinned: Bool) -> [TabID]? { nil }
}
