import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

/// Applies cmux.json `workspaceGroups` (``WorkspaceGroupConfig``) to the groups the sidebar
/// shows: a group's entry is found by its anchor's folder (the folder of its first workspace),
/// and its color and icon draw instead of the group's own. The entry's placement and menu rows
/// are read where a new workspace goes in the group and where its header menu is built.
@MainActor
struct WorkspaceGroupConfigLook {
    let config: WorkspaceGroupConfig
    let machines: MachineRegistry

    /// The folder a group's entry is looked up by: the folder of its first workspace (a terminal's
    /// folder, the selected one first). Nil when the group has no workspace with a folder.
    static func anchorDirectory(of workspaces: [WorkspaceModel]) -> String? {
        workspaces.lazy.compactMap(Self.directory(of:)).first
    }

    /// The folder of `workspace`'s first terminal.
    static func directory(of workspace: WorkspaceModel) -> String? {
        let terminals = workspace.screens.lazy.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty }
        return terminals.compactMap { $0.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { $0.hasPrefix("/") }
    }

    /// The anchor folder of the sidebar group `group` (its rows in order).
    func anchorDirectory(of group: SidebarGroup) -> String? {
        Self.anchorDirectory(of: group.workspaces.compactMap { machines.workspace(id: $0.id.rawValue)?.0 })
    }

    /// `sections` with each configured group's color and icon drawn from its entry.
    func applying(to sections: [SidebarRowSection]) -> [SidebarRowSection] {
        guard !config.byCwd.isEmpty else { return sections }
        return sections.map { section in
            var drawn = section
            drawn.nodes = section.nodes.map { node in
                guard case .group(var group) = node, let entry = config.entry(for: anchorDirectory(of: group))?.entry else { return node }
                if let color = entry.color { group.tint = color }
                if let icon = entry.icon, let parsed = WorkspaceIcon.parse(icon) { group.icon = parsed }
                return .group(group)
            }
            return drawn
        }
    }

    /// The header menu rows the group's entry adds, aimed at `target`: each names a catalog action,
    /// a cmux.json `actions` command (`cmuxConfig.<name>`), or `newWorkspace` (New Workspace in Group).
    func menuItems(for group: SidebarGroup?, target: ActionTargetRef, registry: ActionRegistry) -> [NSMenuItem] {
        guard let group, let entry = config.entry(for: anchorDirectory(of: group))?.entry else { return [] }
        return entry.contextMenu.compactMap { row in
            let id = Self.actionID(row.action, in: registry)
            return id.flatMap { registry.makeConfiguredContextItem(for: $0, target: target, title: row.title) }
        }
    }

    /// The registry action a configured row names, nil when none does.
    static func actionID(_ name: String, in registry: ActionRegistry) -> ActionID? {
        if name == "newWorkspace" { return "workspaceGroup.newWorkspace" }
        for candidate in [name, ConfigCommandAction.actionIDPrefix + name] where registry.action(for: ActionID(rawValue: candidate)) != nil {
            return ActionID(rawValue: candidate)
        }
        return nil
    }
}
