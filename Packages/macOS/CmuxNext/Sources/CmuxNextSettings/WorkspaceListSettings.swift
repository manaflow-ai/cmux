public import CmuxNextDesign

/// cmux.json `workspaces.newPlacement`: where a new workspace goes in the
/// sidebar when its entry point names no place (Cmd-N, the palette, the
/// sidebar's +, `cmux workspace new`, Home, a tab moved to a new workspace,
/// a link or an agent opening one).
/// `top` (the default; the daemon places a new workspace by the same rule in
/// its create): first in the group of the workspace the window shows when that
/// one is in a group, and first in a group the new workspace is made in (its
/// header's +, a Chief subagent's group; Lawrence 2026-10-28); outside a group, first in the workspace list, below the Pinned
/// section and the Home row, above every group. `afterCurrent` (cmux classic's
/// default): right after the workspace the window shows, inside its group when
/// it has one (top when that workspace is pinned, Home, or on another machine).
/// `bottom`: last in the
/// group of the workspace the window shows; outside a group, after the last
/// loose workspace, where the daemon puts it. An explicit place (a drop on a
/// sidebar gap, New Workspace Above or Below) always wins; a reopened workspace
/// keeps its old place.
public nonisolated enum NewWorkspacePlacement: String, Hashable, Sendable, CaseIterable {
    case top, afterCurrent, bottom
}

/// The workspace list's shape (Lawrence 2026-10-08, cx-plf5): new workspaces
/// at the top (`workspaces.newPlacement`; #23014 made it afterCurrent on
/// 2026-10-20, back to top the same day: Lawrence asked for Cmd-N to always put
/// it at the top, and the daemon's default is top) and one list without computer
/// headers unless `sidebar.groupByComputer` is on
/// (`SidebarSectionsPreferences.groupsByComputer`). A workspace the user
/// never named takes its front tab's name unless `workspaces.autoName` is
/// off (hq#1957, `SidebarSectionsPreferences.autoNamesWorkspaces`).
nonisolated extension CmuxConfigSnapshot {
    public static let newWorkspacePlacementPath = ["workspaces", "newPlacement"]
    public static let newWorkspacePlacementFallback: NewWorkspacePlacement = .top
    public static let groupByComputerPath = ["sidebar", "groupByComputer"]
    public static let autoNameWorkspacesPath = ["workspaces", "autoName"]

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic. Runs after `sidebarSections` is parsed.
    static func parseWorkspaceList(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.newWorkspacePlacement = ColumnLayoutSettings.choice(root, newWorkspacePlacementPath, fallback: newWorkspacePlacementFallback,
                                                                     diagnostics: &snapshot.diagnostics)
        if let flag = flag(root, groupByComputerPath, diagnostics: &snapshot.diagnostics) { snapshot.sidebarSections.groupsByComputer = flag }
        if let flag = flag(root, autoNameWorkspacesPath, diagnostics: &snapshot.diagnostics) { snapshot.sidebarSections.autoNamesWorkspaces = flag }
    }

    /// The boolean at `path`; nil when missing, or invalid (plus a diagnostic).
    private static func flag(_ root: JSONValue, _ path: [String], diagnostics: inout [SettingsDiagnostic]) -> Bool? {
        guard let value = root.value(at: path) else { return nil }
        if let flag = value.boolValue { return flag }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        return nil
    }
}

/// The three rows, in the General section's Sidebar group.
nonisolated enum WorkspaceListSettingsSchema {
    /// Agents may change all three: list shape and order choices, like `layout.newPanePlacement`, and
    /// whether unnamed workspaces take their tab's name (a user's name always wins).
    static var agentSettableKeys: Set<String> {
        [CmuxConfigSnapshot.newWorkspacePlacementPath, CmuxConfigSnapshot.groupByComputerPath, CmuxConfigSnapshot.autoNameWorkspacesPath]
            .reduce(into: []) { $0.insert($1.joined(separator: ".")) }
    }

    static var descriptors: [SettingDescriptor] {
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        return [
            SettingDescriptor(
                CmuxConfigSnapshot.newWorkspacePlacementPath, section: .general, group: sidebar,
                title: SettingsText.keyed("settings.workspaces.newPlacement", "New Workspace Position"),
                help: SettingsText.keyed("settings.workspaces.newPlacement.help",
                                        "Where Cmd-N, the + button and the CLI put a new workspace in the sidebar. A workspace made in a group goes to the same place inside that group. Pinned workspaces stay above it."),
                kind: .choice([
                    SettingChoice(NewWorkspacePlacement.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                    SettingChoice(NewWorkspacePlacement.afterCurrent.rawValue,
                                  SettingsText.keyed("settings.choice.afterCurrentWorkspace", "After Current Workspace")),
                    SettingChoice(NewWorkspacePlacement.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                ]),
                default: .string(CmuxConfigSnapshot.newWorkspacePlacementFallback.rawValue),
                keywords: ["workspace", "new", "cmd-n", "position", "order", "top", "bottom", "after", "sidebar", "placement"]
            ),
            SettingDescriptor(
                CmuxConfigSnapshot.groupByComputerPath, section: .general, group: sidebar,
                title: SettingsText.keyed("settings.sidebar.groupByComputer", "Group Workspaces by Computer"),
                help: SettingsText.keyed("settings.sidebar.groupByComputer.help",
                                        "Off: one list of workspaces, and a workspace on another computer names it under its title. On: a section per computer."),
                kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.groupsByComputer),
                keywords: ["sidebar", "computer", "machine", "cloud", "remote", "group", "section", "header", "flat", "list"]
            ),
            SettingDescriptor(
                CmuxConfigSnapshot.autoNameWorkspacesPath, section: .general, group: sidebar,
                title: SettingsText.keyed("settings.workspaces.autoName", "Name Workspaces from Tabs"),
                help: SettingsText.keyed("settings.workspaces.autoName.help",
                                        "A workspace you have not named shows its front tab's name: a page's title, an agent chat's title, or a terminal's title or folder. Your own name always wins."),
                kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.autoNamesWorkspaces),
                keywords: ["workspace", "name", "rename", "auto", "title", "tab", "chat", "page", "folder", "sidebar"]
            ),
        ]
    }
}
