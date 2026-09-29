import Foundation

/// A collapsible group of workspaces inside a machine section.
public nonisolated struct SidebarGroup: Identifiable, Hashable, Sendable {
    public var id: GroupID
    public var name: String
    public var color: SidebarColor
    public var isCollapsed: Bool
    public var workspaces: [SidebarWorkspace]

    public init(id: GroupID, name: String, color: SidebarColor = .gray, isCollapsed: Bool = false, workspaces: [SidebarWorkspace]) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.workspaces = workspaces
    }

    /// Aggregate unread count shown on a collapsed group header.
    public var unreadTotal: Int {
        workspaces.reduce(0) { total, ws in
            switch ws.unread {
            case .none: total
            case .dot: total + 1
            case let .count(n): total + n
            }
        }
    }

    /// Strongest activity among children, shown on a collapsed group header.
    public var aggregateActivity: AgentActivity {
        let all = workspaces.map(\.activity)
        if all.contains(.error) { return .error }
        if all.contains(.needsInput) { return .needsInput }
        if all.contains(.running) { return .running }
        return .idle
    }
}

/// A child of a section: a loose workspace or a group.
public nonisolated enum SidebarNode: Identifiable, Hashable, Sendable {
    case workspace(SidebarWorkspace)
    case group(SidebarGroup)

    public nonisolated enum ID: Hashable, Sendable {
        case workspace(WorkspaceID)
        case group(GroupID)
    }

    public var id: ID {
        switch self {
        case let .workspace(ws): .workspace(ws.id)
        case let .group(group): .group(group.id)
        }
    }

    /// Every workspace in this node, in visual order.
    public var workspaces: [SidebarWorkspace] {
        switch self {
        case let .workspace(ws): [ws]
        case let .group(group): group.workspaces
        }
    }
}
