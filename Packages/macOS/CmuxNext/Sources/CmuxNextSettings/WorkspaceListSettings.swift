public import CmuxNextDesign

/// cmux.json `workspaces.newPlacement`: where a new workspace goes in the
/// sidebar when its entry point names no place (Cmd-N, the palette, the
/// sidebar's +, `cmux workspace new`, Home, a tab moved to a new workspace).
/// `top` (the default): first in the workspace list, below the Pinned section
/// and the Home row, above every group. `afterCurrent`: right after the
/// workspace the window shows, inside its group when it has one (top when that
/// workspace is pinned, Home, or on another machine). `bottom`: after the last
/// loose workspace, where the daemon puts it. An explicit place (a drop on a
/// sidebar gap, New Workspace Above or Below) always wins; a reopened workspace
/// keeps its old place.
public nonisolated enum NewWorkspacePlacement: String, Hashable, Sendable, CaseIterable {
    case top, afterCurrent, bottom
}

/// The workspace list's shape (Lawrence 2026-10-08, cx-plf5): new workspaces
/// at the top (`workspaces.newPlacement`) and one list without computer
/// headers unless `sidebar.groupByComputer` is on
/// (`SidebarSectionsPreferences.groupsByComputer`).
nonisolated extension CmuxConfigSnapshot {
    public static let newWorkspacePlacementPath = ["workspaces", "newPlacement"]
    public static let newWorkspacePlacementFallback: NewWorkspacePlacement = .top
    public static let groupByComputerPath = ["sidebar", "groupByComputer"]

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic. Runs after `sidebarSections` is parsed.
    static func parseWorkspaceList(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.newWorkspacePlacement = ColumnLayoutSettings.choice(root, newWorkspacePlacementPath, fallback: newWorkspacePlacementFallback,
                                                                     diagnostics: &snapshot.diagnostics)
        guard let value = root.value(at: groupByComputerPath) else { return }
        if let flag = value.boolValue {
            snapshot.sidebarSections.groupsByComputer = flag
        } else {
            snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: groupByComputerPath.joined(separator: "."),
                                                           message: "expected true or false"))
        }
    }
}

/// The two rows, in the General section's Sidebar group.
nonisolated enum WorkspaceListSettingsSchema {
    /// Agents may change both: list shape and order choices, like `layout.newPanePlacement`.
    static var agentSettableKeys: Set<String> {
        [CmuxConfigSnapshot.newWorkspacePlacementPath, CmuxConfigSnapshot.groupByComputerPath].reduce(into: []) { $0.insert($1.joined(separator: ".")) }
    }

    static var descriptors: [SettingDescriptor] {
        let sidebar = SettingsText.keyed("settings.group.sidebar", "Sidebar")
        return [
            SettingDescriptor(
                CmuxConfigSnapshot.newWorkspacePlacementPath, section: .general, group: sidebar,
                title: SettingsText.keyed("settings.workspaces.newPlacement", "New Workspace Position"),
                help: SettingsText.keyed("settings.workspaces.newPlacement.help",
                                        "Where Cmd-N, the + button and the CLI put a new workspace in the sidebar. Pinned workspaces stay above it."),
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
        ]
    }
}
