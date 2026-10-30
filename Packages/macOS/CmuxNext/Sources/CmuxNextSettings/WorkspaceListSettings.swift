public import CmuxNextDesign

/// cmux.json `workspaces.newPlacement`: where a new workspace goes in the
/// sidebar when its entry point names no place (Cmd-N, the palette, the
/// sidebar's +, `cmux workspace new`, Home, a tab moved to a new workspace,
/// a link or an agent opening one).
/// `afterCurrent` (the default): right after the workspace the window shows,
/// inside its group when it has one (top when that workspace is pinned, Home,
/// or on another machine). `bottom` (Chrome-style): after the last loose
/// workspace, or at the end of the current group. `top` remains readable for
/// older config files and keeps its historical behavior. An explicit place (a
/// drop on a sidebar gap, New Workspace Above or Below) always wins; a
/// reopened workspace keeps its old place.
public nonisolated enum NewWorkspacePlacement: String, Hashable, Sendable, CaseIterable {
    case top, afterCurrent, bottom
}

/// The workspace list's shape (Lawrence 2026-10-08, cx-plf5): new workspaces
/// next to the current workspace by default (`workspaces.newPlacement`; the
/// daemon uses the same rule in its create) and one list without computer
/// headers unless `sidebar.groupByComputer` is on
/// (`SidebarSectionsPreferences.groupsByComputer`). A workspace the user
/// never named takes its front tab's name unless `workspaces.autoName` is
/// off (hq#1957, `SidebarSectionsPreferences.autoNamesWorkspaces`).
nonisolated extension CmuxConfigSnapshot {
    public static let newWorkspacePlacementPath = ["workspaces", "newPlacement"]
    public static let newWorkspacePlacementFallback: NewWorkspacePlacement = .afterCurrent
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
                title: SettingsText.keyed("settings.workspaces.newPlacement", "New workspaces go to"),
                help: SettingsText.keyed("settings.workspaces.newPlacement.help",
                                        "Where Cmd-N, the + button and the CLI put a new workspace in the sidebar. The default keeps it next to the current workspace; a workspace made in a group stays in that group."),
                kind: .choice([
                    SettingChoice(NewWorkspacePlacement.afterCurrent.rawValue,
                                  SettingsText.keyed("settings.choice.afterCurrentWorkspace", "Next to current")),
                    SettingChoice(NewWorkspacePlacement.bottom.rawValue,
                                  SettingsText.keyed("settings.choice.bottomChromeStyle", "Bottom (Chrome-style)")),
                ]),
                default: .string(CmuxConfigSnapshot.newWorkspacePlacementFallback.rawValue),
                keywords: ["workspace", "new", "cmd-n", "position", "order", "next", "current", "bottom", "sidebar", "placement"]
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
