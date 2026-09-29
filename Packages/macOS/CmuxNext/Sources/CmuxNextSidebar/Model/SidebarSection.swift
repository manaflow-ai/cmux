import Foundation

/// A top-level sidebar section: the pinned area or one machine.
public nonisolated enum SectionID: Hashable, Sendable {
    case pinned
    case machine(MachineID)
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
