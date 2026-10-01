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
    /// tab, `groupTabs` the group's tabs in strip order. Today it always
    /// opens a terminal tab in the pane.
    static func requestInGroup(selected: String?, groupTabs: [String], pane: String,
                               perform: (ActionID, ActionInvocation) -> Void) {
        perform("newSurface", ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
    }
}
