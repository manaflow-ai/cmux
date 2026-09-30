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
        /// Connected, but the machine's cmux-tui lacks features this app
        /// uses; they stay off until the machine is updated.
        case updateAvailable
        /// The machine's cmux-tui is too old for this app; nothing connects
        /// until the machine is updated.
        case updateRequired
        /// cmux-tui is missing on the machine (or does not run there).
        case installRequired
        /// cmux-tui is being installed on the machine.
        case installing
        /// SSH refused the key, or the host key is not trusted.
        case authFailed
        /// The network cannot reach the machine; retried on network change.
        case unreachable
    }

    public var id: MachineID
    public var name: String
    public var kind: Kind
    public var status: Status
    /// Tooltip for the header: why an update is needed and what it enables.
    public var detail: String?

    public init(id: MachineID, name: String, kind: Kind, status: Status = .connected, detail: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.detail = detail
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
