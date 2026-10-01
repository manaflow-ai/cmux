public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section for the local daemon, loose workspaces first, then groups.
public enum SidebarMapping {
    /// `status` gives a workspace's reported status (`cmux workspace
    /// status|progress|log`, usually `DaemonStore.status(of:)`), the row's
    /// live lines. The cwd stays passive detail (hover card, accessibility).
    public static func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                showsUnread: Bool = true,
                                status: (WorkspaceModel) -> WorkspaceStatusSnapshot? = { _ in nil }) -> [SidebarRowSection] {
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            let rows = section.workspaces.map { row($0, machine: machine.id, status: status($0), showsUnread: showsUnread) }
            if let group = section.group {
                nodes.append(.group(SidebarGroup(
                    id: GroupID(group.id.rawValue),
                    name: group.name,
                    color: color(group.color) ?? .grey,
                    isCollapsed: group.collapsed || collapsedGroups.contains(group.id.rawValue),
                    workspaces: rows
                )))
            } else {
                nodes += rows.map(SidebarNode.workspace)
            }
        }
        return [SidebarRowSection(kind: .machine(machine), nodes: nodes)]
    }

    /// `showsUnread: false` hides the unread badge (`notifications.attention.showOnSidebar`).
    public static func row(_ workspace: WorkspaceModel, machine: MachineID, status: WorkspaceStatusSnapshot? = nil,
                           showsUnread: Bool = true) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        return SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            title: workspace.displayName,
            subtitle: subtitle(tabs),
            status: status.map(Self.status).flatMap { $0.isEmpty ? nil : $0 },
            icon: color(workspace.color).map(WorkspaceIcon.swatch) ?? workspace.icon.map { WorkspaceIcon.symbol($0) },
            unread: unread > 0 ? .count(unread) : .none,
            activity: activity(tabs)
        )
    }

    /// The sidebar's form of a daemon status snapshot. Unknown log levels
    /// read as info; colors the sidebar cannot parse draw uncolored.
    public static func status(_ snapshot: WorkspaceStatusSnapshot) -> SidebarWorkspaceStatus {
        SidebarWorkspaceStatus(
            entries: snapshot.entries.map { entry in
                SidebarWorkspaceStatus.Entry(key: entry.key, text: entry.text, icon: entry.icon,
                                             tint: SidebarWorkspaceStatus.Tint(entry.color))
            },
            progress: snapshot.progress.map { SidebarWorkspaceStatus.Progress(value: $0.value, label: $0.label) },
            log: snapshot.lastLog.map { line in
                SidebarWorkspaceStatus.LogLine(level: SidebarWorkspaceStatus.LogLevel(rawValue: line.level) ?? .info, text: line.text)
            }
        )
    }

    /// cwd of the first tab that reports one, `~`-abbreviated, plus branch.
    static func subtitle(_ tabs: [TabModel]) -> String? {
        guard let tab = tabs.first(where: { $0.cwd != nil }), let cwd = tab.cwd else { return nil }
        let path = abbreviate(cwd)
        guard let branch = tab.gitBranch, !branch.isEmpty else { return path }
        return "\(path) · \(branch)"
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func activity(_ tabs: [TabModel]) -> AgentActivity {
        let states = tabs.compactMap { $0.agent?.state }
        if states.contains(.blocked) { return .needsInput }
        if states.contains(.working) { return .running }
        return .idle
    }

    public static func color(_ name: String?) -> GroupColor? {
        guard let name else { return nil }
        return GroupColor(rawValue: name.lowercased()) ?? (name.lowercased() == "gray" ? .grey : nil)
    }
}
