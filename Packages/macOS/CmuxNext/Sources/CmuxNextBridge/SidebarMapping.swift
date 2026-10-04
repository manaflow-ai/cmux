import CmuxAgentBrands
public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextDesign
import Foundation

/// Maps the daemon store's sidebar flattening into sidebar rows: one machine
/// section for the local daemon, loose workspaces first, then groups.
public struct SidebarMapping {
    public static let shared = Self()
    /// The workspace kind of the home workspace (`workspace-kind-v1`).
    public static let homeKind = "home"
    /// `statusLine` maps a workspace id to the status hooks reported
    /// (`set_status`), the row's live second line. The cwd stays passive
    /// detail (tooltip, accessibility).
    public func sections(_ daemonSections: [DaemonSidebarSection], machine: SidebarMachine,
                                collapsedGroups: Set<String> = [],
                                hidesHomeWorkspace: Bool = true,
                                showsUnread: Bool = true,
                                statusLine: (String) -> String? = { _ in nil },
                                title: (WorkspaceModel) -> String? = { _ in nil }) -> [SidebarRowSection] {
        var nodes: [SidebarNode] = []
        for section in daemonSections {
            // The home workspace (`kind` "home") is what the Home item in the
            // top section shows; it is not also a workspace row (nxdog28)
            // while that item is in the layout (`hidesHomeWorkspace`).
            let rows = section.workspaces.filter { !hidesHomeWorkspace || $0.kind != Self.homeKind }
                .map { row($0, machine: machine.id, status: statusLine($0.id), showsUnread: showsUnread, title: title($0)) }
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
    /// `title` replaces the workspace's own name (an app's companion
    /// workspace with its default name, `AppTabsTitle`).
    public func row(_ workspace: WorkspaceModel, machine: MachineID, status: String? = nil, showsUnread: Bool = true,
                    title: String? = nil) -> SidebarWorkspace {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let unread = showsUnread ? workspace.unreadCount : 0
        let indicator = StatusMapping.shared.summary(tabs: tabs)
        return SidebarWorkspace(
            id: SidebarWorkspaceID(workspace.id),
            machineID: machine,
            title: title ?? workspace.displayName,
            subtitle: subtitle(tabs),
            // The hooks' status line, else the daemon's workspace status (state resources).
            status: (status ?? workspace.status?.line).flatMap { $0.isEmpty ? nil : $0 },
            icon: Self.icon(color: workspace.color, icon: workspace.icon),
            unread: unread > 0 ? .count(unread) : (showsUnread && workspace.markedUnread ? .dot : .none),
            activity: indicator.state,
            activityStyle: indicator.style,
            agentBrand: agentBrand(tabs),
            progress: progress(workspace, tabs: tabs),
            tabs: tabs.map { tab in
                SidebarTab(id: TabID(tab.id), title: tab.displayTitle, kind: Self.tabKind(tab.kind), isUnread: tab.hasUnread)
            }
        )
    }

    /// The brand of the first agent that works or waits in these tabs (design/agent-icons).
    func agentBrand(_ tabs: [TabModel]) -> String? {
        tabs.lazy.compactMap { tab -> String? in
            guard let agent = tab.agent, agent.state == .working || agent.state == .blocked else { return nil }
            return AgentBrandCatalog.brand(for: agent.agent)?.rawValue
        }.first
    }

    private static func tabKind(_ kind: TabKind) -> SidebarTabKind {
        switch kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        case .conversation: .conversation
        case .app: .other("app")
        case let .other(value): .other(value)
        }
    }

    /// The workspace's reported progress, else the first terminal progress
    /// the daemon parsed for one of its tabs (mounted or not).
    public func progress(_ workspace: WorkspaceModel, tabs: [TabModel]) -> SidebarProgress? {
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

    /// A workspace's sidebar icon: its icon with its color (a tinted symbol,
    /// an emoji on a color chip), else its color as a swatch, else none.
    public static func icon(color name: String?, icon: String?) -> WorkspaceIcon? {
        let color = shared.color(name)
        return icon.flatMap { WorkspaceIcon.parse($0, color: color) } ?? color.map(WorkspaceIcon.swatch)
    }

    public func color(_ name: String?) -> GroupColor? {
        guard let name else { return nil }
        return GroupColor(rawValue: name.lowercased()) ?? (name.lowercased() == "gray" ? .grey : nil)
    }
}
