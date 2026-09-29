import Foundation

// Value types the sidebar renders. The App layer maps daemon state into these;
// the sidebar never talks to a daemon itself.

/// Stable identifier of a workspace. For daemon workspaces this is the
/// daemon's `ws_…` id, qualified by machine when ids can collide.
public nonisolated struct WorkspaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Stable identifier of a workspace group.
public nonisolated struct GroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// A fresh id for a group the user just created in the UI.
    public static func make() -> GroupID { GroupID("grp_" + UUID().uuidString.lowercased()) }
    public var description: String { rawValue }
}

/// Stable identifier of a machine (one cmux-tui daemon session).
public nonisolated struct MachineID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let local = MachineID("local")
    public var description: String { rawValue }
}

/// A top-level sidebar section: the pinned area or one machine.
public nonisolated enum SectionID: Hashable, Sendable {
    case pinned
    case machine(MachineID)
}

/// User-selectable colors for groups, swatches, and tints. These are content
/// colors picked by the user, never UI accents.
public nonisolated enum SidebarColor: String, CaseIterable, Sendable, Codable {
    case gray, red, orange, yellow, green, mint, cyan, blue, purple, pink
}

/// Workspace icon: an SF Symbol (optionally tinted) or a color swatch.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: SidebarColor? = nil)
    case swatch(SidebarColor)
}

/// Agent activity shown as a small indicator on the row.
public nonisolated enum AgentActivity: Hashable, Sendable {
    case idle
    case running
    case needsInput
    case error
}

/// Unread state for the badge.
public nonisolated enum UnreadState: Hashable, Sendable {
    case none
    case dot
    case count(Int)

    public var isUnread: Bool {
        switch self {
        case .none: false
        case .dot: true
        case let .count(n): n > 0
        }
    }
}

/// One workspace row.
public nonisolated struct SidebarWorkspace: Identifiable, Hashable, Sendable {
    public var id: WorkspaceID
    /// The machine whose daemon owns this workspace. Workspaces never move
    /// between machines; drops across machine sections are refused.
    public var machineID: MachineID
    public var title: String
    /// cwd, git branch, or the agent status line.
    public var subtitle: String?
    public var icon: WorkspaceIcon
    public var unread: UnreadState
    public var activity: AgentActivity

    public init(
        id: WorkspaceID,
        machineID: MachineID = .local,
        title: String,
        subtitle: String? = nil,
        icon: WorkspaceIcon = .symbol("terminal"),
        unread: UnreadState = .none,
        activity: AgentActivity = .idle
    ) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.unread = unread
        self.activity = activity
    }
}

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

/// Machine metadata for a machine section header.
public nonisolated struct SidebarMachine: Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case local
        case cloud
        case ssh
    }

    public nonisolated enum Status: Hashable, Sendable {
        case connected
        case connecting
        case offline
    }

    public var id: MachineID
    public var name: String
    public var kind: Kind
    public var status: Status

    public init(id: MachineID, name: String, kind: Kind, status: Status = .connected) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
    }
}

/// A top-level section.
public nonisolated struct SidebarSection: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        /// Arc-style favorites. Holds loose workspaces from any machine; no groups.
        case pinned
        case machine(SidebarMachine)
    }

    public var kind: Kind
    public var isCollapsed: Bool
    public var nodes: [SidebarNode]

    public init(kind: Kind, isCollapsed: Bool = false, nodes: [SidebarNode]) {
        self.kind = kind
        self.isCollapsed = isCollapsed
        self.nodes = nodes
    }

    public var id: SectionID {
        switch kind {
        case .pinned: .pinned
        case let .machine(machine): .machine(machine.id)
        }
    }

    public var machine: SidebarMachine? {
        if case let .machine(machine) = kind { return machine }
        return nil
    }

    /// Every workspace in this section, in visual order.
    public var workspaces: [SidebarWorkspace] { nodes.flatMap(\.workspaces) }
}

/// How the sidebar occupies the window.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case expanded
    case iconsOnly
    case hidden
}
