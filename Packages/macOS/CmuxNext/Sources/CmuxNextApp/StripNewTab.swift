import CmuxNextActions

/// The tab strip's "+" (a click, a double-click on the empty strip): one
/// registry action on the strip's pane, so it matches every other entry
/// point of that action.
enum StripNewTab {
    static let action: ActionID = "newTab.sameKind"

    static func request(pane: String, perform: (ActionID, ActionInvocation) -> Void) {
        perform(action, ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
    }
}
