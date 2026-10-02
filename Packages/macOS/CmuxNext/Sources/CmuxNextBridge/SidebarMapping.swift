public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section for the local daemon, loose workspaces first, then groups.
public struct SidebarMapping {
    public static let shared = Self()
    /// A row's live second line is the status hooks and the CLI reported
    /// to the workspace's daemon (`WorkspaceModel.status`); the cwd stays
    /// passive detail (tooltip, accessibility).
    public func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                showsUnread: Bool = true) -> [SidebarRowSection] {
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            let rows = section.workspaces.map { row($0, machine: machine.id, showsUnread: showsUnread) }
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
    public func row(_ workspace: WorkspaceModel, machine: MachineID, showsUnread: Bool = true) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        let indicator = StatusMapping.shared.summary(tabs: tabs)
        return SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            title: workspace.displayName,
            subtitle: subtitle(tabs),
            status: workspace.status?.line,
            icon: color(workspace.color).map(WorkspaceIcon.swatch) ?? workspace.icon.map { WorkspaceIcon.symbol($0) },
            unread: unread > 0 ? .count(unread) : (showsUnread && workspace.markedUnread ? .dot : .none),
            activity: indicator.state,
            activityStyle: indicator.style,
            progress: progress(workspace, tabs: tabs)
        )
    }

    /// The workspace's reported progress, else the first terminal progress
    /// the daemon parsed for one of its tabs (mounted or not).
    func progress(_ workspace: WorkspaceModel, tabs: [TabModel]) -> SidebarProgress? {
        if let reported = workspace.status?.progress { return SidebarProgress(value: reported.value) }
        guard let terminal = tabs.lazy.compactMap(\.progress).first else { return nil }
        return Self.progress(terminal)
    }

    /// A terminal's OSC 9;4 progress as a bar; nil for a paused one with no value.
    public static func progress(_ report: TerminalProgressReport) -> SidebarProgress? {
        let value = report.value.map { Double($0) / 100 }
        switch report.state {
        case .normal: return SidebarProgress(value: value)
        case .error: return SidebarProgress(value: value ?? 1, isError: true)
        case .indeterminate: return SidebarProgress(value: nil)
        case .paused: return value.map { SidebarProgress(value: $0) }
        }
    }

    /// cwd of the first tab that reports one, `~`-abbreviated, plus branch.
    func subtitle(_ tabs: [TabModel]) -> String? {
        guard let tab = tabs.first(where: { $0.cwd != nil }), let cwd = tab.cwd else { return nil }
        let path = abbreviate(cwd)
        guard let branch = tab.gitBranch, !branch.isEmpty else { return path }
        return "\(path) · \(branch)"
    }

    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public func color(_ name: String?) -> GroupColor? {
        guard let name else { return nil }
        return GroupColor(rawValue: name.lowercased()) ?? (name.lowercased() == "gray" ? .grey : nil)
    }
}
