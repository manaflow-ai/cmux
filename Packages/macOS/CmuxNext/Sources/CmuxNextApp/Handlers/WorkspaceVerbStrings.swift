import Foundation

/// Refusals of the workspace verbs (Resources/WorkspaceVerbs.xcstrings).
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
    static var otherMachine: String { text("workspaceVerbs.refusal.otherMachine", "tabs cannot move to a workspace on another machine") }
    static var onlyPane: String { text("workspaceVerbs.refusal.onlyPane", "the pane is the only pane of its workspace") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "WorkspaceVerbs", bundle: .module)
    }
}
