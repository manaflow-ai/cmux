import Foundation

/// Refusals and menu titles of the workspace verbs (Resources/WorkspaceVerbs.xcstrings).
nonisolated enum WorkspaceVerbStrings {
    /// The local machine in a machine list.
    static var thisMac: String { text("workspaceVerbs.thisMac", "This Mac") }
    static var noDirectory: String { text("workspaceVerbs.refusal.noDirectory", "the workspace has no terminal with a known directory") }
    static var noMachine: String { text("workspaceVerbs.refusal.noMachine", "a machine argument naming a connected machine is required") }
    static var machineNotConnected: String { text("workspaceVerbs.refusal.machineNotConnected", "the machine is not connected") }
    static var noLastUsed: String { text("workspaceVerbs.refusal.noLastUsed", "this window has not shown another workspace yet") }
    static var invalidIcon: String { text("workspaceVerbs.refusal.invalidIcon", "the icon must be an SF Symbol name or one emoji") }
    static var mergeTargetRequired: String { text("workspaceVerbs.refusal.mergeTargetRequired", "an into argument naming a workspace is required") }
    static var mergeIntoItself: String { text("workspaceVerbs.refusal.mergeIntoItself", "a workspace cannot merge into itself") }
    static var mergeIntoHome: String { text("workspaceVerbs.refusal.mergeIntoHome", "a workspace cannot merge into Home") }
    static var otherMachine: String { text("workspaceVerbs.refusal.otherMachine", "tabs cannot move to a workspace on another machine") }
    static var onlyPane: String { text("workspaceVerbs.refusal.onlyPane", "the pane is the only pane of its workspace") }
    /// A grouped row's Move to Top and Move to Bottom (they move it inside its group).
    static var moveToTopOfGroup: String { text("workspaceVerbs.moveToTopOfGroup", "Move to Top of Group") }
    static var moveToBottomOfGroup: String { text("workspaceVerbs.moveToBottomOfGroup", "Move to Bottom of Group") }
    /// A group header's Pin row, titled as the change it makes (pinned groups list first).
    static var pinGroup: String { text("workspaceVerbs.pinGroup", "Pin Group") }
    static var unpinGroup: String { text("workspaceVerbs.unpinGroup", "Unpin Group") }
    /// A group header's Collapse/Expand row, titled as the change it makes.
    static var collapseGroup: String { text("workspaceVerbs.collapseGroup", "Collapse Group") }
    static var subgroupTooDeep: String { text("workspaceVerbs.refusal.subgroupTooDeep", "groups nest at most 16 levels deep") }
    static var subgroupNeedsDocument: String { text("workspaceVerbs.refusal.subgroupNeedsDocument", "this sidebar cannot nest groups yet") }
    static var expandGroup: String { text("workspaceVerbs.expandGroup", "Expand Group") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "WorkspaceVerbs", bundle: .module)
    }
}
