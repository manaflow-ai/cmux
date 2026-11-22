import CmuxNextActions

/// The tab strip's "+" (a click, a double-click on the empty strip): one
/// registry action on the strip's pane, so it matches every other entry
/// point of that action.
enum StripNewTab {
    static let action: ActionID = "newTab.sameKind"

    static func request(pane: String, opensWorkspace: Bool = false, perform: (ActionID, ActionInvocation) -> Void) {
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane))
        if opensWorkspace { invocation.arguments["toggleWorkspace"] = .bool(true) }
        perform(action, invocation)
    }

    /// The tab group editor's New Tab. `selected` is the pane's selected
    /// tab, `groupTabs` the group's tabs in strip order. The group's
    /// selected tab decides the kind (`newTab.sameKind` on that tab), else
    /// its last tab (cmux keeps no per-tab focus history); a group without
    /// tabs gets a terminal tab in the pane.
    static func requestInGroup(selected: String?, groupTabs: [String], pane: String,
                               opensWorkspace: Bool = false,
                               perform: (ActionID, ActionInvocation) -> Void) {
        let source = selected.flatMap { groupTabs.contains($0) ? $0 : nil } ?? groupTabs.last
        guard let source else {
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane))
            if opensWorkspace { invocation.arguments["toggleWorkspace"] = .bool(true) }
            return perform("newSurface", invocation)
        }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: source))
        if opensWorkspace { invocation.arguments["toggleWorkspace"] = .bool(true) }
        perform(action, invocation)
    }
}
