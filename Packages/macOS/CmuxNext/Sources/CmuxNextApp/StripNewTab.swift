import CmuxNextActions

/// The tab strip's "+" (a click, a double-click on the empty strip): one
/// registry action on the strip's pane, so it matches every other entry
/// point of that action.
enum StripNewTab {
    static let action: ActionID = "newTab.sameKind"

    static func request(pane: String, perform: (ActionID, ActionInvocation) -> Void) {
        perform(action, ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
    }

    /// The tab group editor's New Tab. `selected` is the pane's selected
    /// tab, `groupTabs` the group's tabs in strip order. The group's
    /// selected tab decides the kind (`newTab.sameKind` on that tab), else
    /// its last tab (cmux keeps no per-tab focus history); a group without
    /// tabs gets a terminal tab in the pane.
    static func requestInGroup(selected: String?, groupTabs: [String], pane: String,
                               perform: (ActionID, ActionInvocation) -> Void) {
        let source = selected.flatMap { groupTabs.contains($0) ? $0 : nil } ?? groupTabs.last
        guard let source else {
            return perform("newSurface", ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
        }
        perform(action, ActionInvocation(target: ActionTargetRef(kind: .tab, id: source)))
    }
}
