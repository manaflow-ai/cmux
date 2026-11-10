public import CmuxNextDesign

/// cmux.json `workspaces.newPlacement`: where a new workspace goes in the
/// sidebar when its entry point names no place (Cmd-N, the palette, the
/// sidebar's +, `cmux workspace new`, Home, a tab moved to a new workspace,
/// a link or an agent opening one).
/// `afterCurrent` (the default, as in cmux classic; the daemon places a new
/// workspace by the same rule in its create): right after the workspace the
/// window shows, inside its group when it has one, and where that one was when
/// it closes during the create; from a group's own + with none of its members
/// shown, last in that group; top when that workspace is pinned, Home, or on
/// another machine, never the end of the sidebar (Leo 2026-11-06: "you should
/// just have it right next to it"). `top`: first in the group of the workspace
/// the window shows when that one is in a group, and first in a group the new
/// workspace is made in (its header's +, a Chief subagent's group; Lawrence
/// 2026-10-28); outside a group, first in the workspace list, below the Pinned
/// section and the Home row, above every group. `beforeCurrent` (opt-in):
/// `afterCurrent`'s mirror, right before the workspace the window shows.
/// `bottom`: last in the
/// group of the workspace the window shows; outside a group, after the last
/// loose workspace, where the daemon puts it. An explicit place (a drop on a
/// sidebar gap, New Workspace Above or Below) always wins; a reopened workspace
/// keeps its old place.
public nonisolated enum NewWorkspacePlacement: String, Hashable, Sendable, CaseIterable {
    case top, beforeCurrent, afterCurrent, bottom
}

/// The workspace list's shape (Lawrence 2026-10-08, cx-plf5): new workspaces
/// right after the current one (`workspaces.newPlacement`; #23014 made it
/// afterCurrent on 2026-10-20, back to top the same day at Lawrence's ask, and
/// afterCurrent again on 2026-11-06 at Leo's) and one list without computer
/// headers unless `sidebar.groupByComputer` is on
/// (`SidebarSectionsPreferences.groupsByComputer`). A workspace the user
/// never named takes its front tab's name unless `workspaces.autoName` is
/// off (hq#1957, `SidebarSectionsPreferences.autoNamesWorkspaces`).
nonisolated extension CmuxConfigSnapshot {
    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic. Runs after `sidebarSections` is parsed.
    static func parseWorkspaceList(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.newWorkspacePlacement = ColumnLayoutSettings.choice(root, newWorkspacePlacementPath, fallback: newWorkspacePlacementDefault,
                                                                     diagnostics: &snapshot.diagnostics)
        snapshot.sidebarSections.groupsByComputer = flag(root, groupByComputerPath, diagnostics: &snapshot.diagnostics) ?? groupByComputerDefault
        snapshot.sidebarSections.autoNamesWorkspaces = flag(root, autoNameWorkspacesPath, diagnostics: &snapshot.diagnostics)
            ?? autoNameWorkspacesDefault
    }

    /// The boolean at `path`; nil when missing, or invalid (plus a diagnostic).
    private static func flag(_ root: JSONValue, _ path: [String], diagnostics: inout [SettingsDiagnostic]) -> Bool? {
        guard let value = root.value(at: path) else { return nil }
        if let flag = value.boolValue { return flag }
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        return nil
    }
}
