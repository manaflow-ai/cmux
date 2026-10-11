import Foundation

/// One "Did you know" tip (BOTTOM-LEFT-CARDS K1): a feature, its one-line
/// benefit and the registry action that "Try It" runs. A tip whose action
/// the user ran is used and never shows again.
nonisolated public struct Tip: Equatable, Sendable, Identifiable {
    public var id: String
    /// The action id ``title`` names and "Try It" runs (also its usage flag).
    public var action: String
    public var title: String
    public var benefit: String

    public init(id: String, action: String, title: String, benefit: String) {
        self.id = id
        self.action = action
        self.title = title
        self.benefit = benefit
    }
}

/// The localized tips catalog, in the order tips are offered. Every action
/// is a palette action (TipCatalogTests checks they are registered).
nonisolated public struct TipCatalog {
    public init() {}

    public static var all: [Tip] {
        [
            Tip(id: "commandPalette", action: "commandPalette",
                title: UpdaterStrings.text("updater.tip.commandPalette.title", "Command Palette"),
                benefit: UpdaterStrings.text("updater.tip.commandPalette.benefit", "Run any cmux action by typing its name.")),
            Tip(id: "splitRight", action: "splitRight",
                title: UpdaterStrings.text("updater.tip.splitRight.title", "Split panes"),
                benefit: UpdaterStrings.text("updater.tip.splitRight.benefit", "Put two terminals side by side in one workspace.")),
            Tip(id: "zoomPane", action: "toggleSplitZoom",
                title: UpdaterStrings.text("updater.tip.zoomPane.title", "Zoom a pane"),
                benefit: UpdaterStrings.text("updater.tip.zoomPane.benefit", "Fill the window with one pane, then go back to the split.")),
            Tip(id: "globalSearch", action: "globalSearch",
                title: UpdaterStrings.text("updater.tip.globalSearch.title", "Search all windows"),
                benefit: UpdaterStrings.text("updater.tip.globalSearch.benefit", "Find text in every window at once.")),
            Tip(id: "lastWorkspace", action: "workspace.selectLastUsed",
                title: UpdaterStrings.text("updater.tip.lastWorkspace.title", "Jump back"),
                benefit: UpdaterStrings.text("updater.tip.lastWorkspace.benefit", "Switch to the workspace you used last.")),
            Tip(id: "workspaceGroups", action: "newWorkspaceGroup",
                title: UpdaterStrings.text("updater.tip.workspaceGroups.title", "Workspace groups"),
                benefit: UpdaterStrings.text("updater.tip.workspaceGroups.benefit", "Keep related workspaces together under one name.")),
            Tip(id: "layoutTemplates", action: "saveLayoutTemplate",
                title: UpdaterStrings.text("updater.tip.layoutTemplates.title", "Layout templates"),
                benefit: UpdaterStrings.text("updater.tip.layoutTemplates.benefit", "Save this layout and open it again in one step.")),
            Tip(id: "renameWorkspace", action: "renameWorkspace",
                title: UpdaterStrings.text("updater.tip.renameWorkspace.title", "Name your workspaces"),
                benefit: UpdaterStrings.text("updater.tip.renameWorkspace.benefit", "Give a workspace a name so it is easy to find.")),
        ]
    }
}
