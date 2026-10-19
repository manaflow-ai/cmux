import Foundation

/// A top-level sidebar section: the pinned area or one machine.
public nonisolated enum SectionID: Hashable, Sendable {
    case pinned
    case machine(MachineID)
    /// A sidebar document section that is not a machine's (Pinned, a
    /// custom section), listed by the list: its document section id.
    case custom(String)
}

/// A sidebar document section the list draws (sidebar-v2): Pinned or a
/// custom section, with its title when it shows one (Pinned shows none).
public nonisolated struct SidebarCustomSection: Hashable, Sendable {
    public var id: String
    public var title: String?
    public var showsTitle: Bool

    public init(id: String, title: String? = nil, showsTitle: Bool = false) {
        self.id = id
        self.title = title
        self.showsTitle = showsTitle
    }
}

/// Machine metadata for a machine section header.
public nonisolated struct SidebarMachine: Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case local
        case cloud
        case ssh
        /// A paired server's Chief brain session (`ServerReach`).
        case server
    }

    public nonisolated enum Status: Hashable, Sendable {
        case connected
        case connecting
        /// The link to the machine dropped (sleep, a network drop or
        /// change) and redials on its own; its programs keep running.
        case reconnecting
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
        /// The machine answers, but its cmux-tui did not start (or the
        /// remote command failed); the detail carries its error.
        case failed

        /// The machine cannot connect until the person acts (sign-in,
        /// network, install or update). In one list its workspaces' second
        /// line names the status (cx-mdo0); no header or status row shows.
        public var needsAttention: Bool {
            switch self {
            case .authFailed, .unreachable, .installRequired, .updateRequired, .failed: true
            case .connected, .connecting, .reconnecting, .offline, .updateAvailable, .installing: false
            }
        }
    }

    public var id: MachineID
    public var name: String
    public var kind: Kind
    public var status: Status
    /// Tooltip for the header: why an update is needed and what it enables.
    public var detail: String?
    /// The machine's own icon (`session-icon-v1`, from the home session
    /// registry), drawn in place of its kind's symbol; nil draws the symbol.
    public var icon: WorkspaceIcon?
    /// The machine is a group of its own in the one-list sidebar too (`sidebar.groupByComputer`
    /// off): its header and status show, and its rows do not name it (a remote host,
    /// plans/cmux-next/remote-hosts.md 9: "a remote host is a group, not a row decoration").
    public var keepsHeaderInList: Bool

    public init(id: MachineID, name: String, kind: Kind, status: Status = .connected, detail: String? = nil,
                icon: WorkspaceIcon? = nil, keepsHeaderInList: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.detail = detail
        self.icon = icon
        self.keepsHeaderInList = keepsHeaderInList
    }

    /// A connected machine whose link redials reads as reconnecting
    /// (cx-z5oif): its socket stays up, so its connection cannot tell.
    public func redialing(_ redialing: Bool) -> SidebarMachine {
        guard redialing, status == .connected || status == .updateAvailable else { return self }
        var machine = self
        machine.status = .reconnecting
        return machine
    }
}

/// A top-level section.
public nonisolated struct SidebarSection: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        /// Favorites. Holds loose workspaces from any machine; no groups.
        case pinned
        case machine(SidebarMachine)
        /// A document section (Pinned, custom) the list draws; any item may sit in it.
        case custom(SidebarCustomSection)
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
        case let .custom(custom): .custom(custom.id)
        }
    }

    /// A document section (Pinned, custom) the list draws; never saved in the window's snapshot.
    public var isDocSection: Bool {
        if case .custom = kind { true } else { false }
    }

    public var machine: SidebarMachine? {
        if case let .machine(machine) = kind { return machine }
        return nil
    }

    /// Every workspace in this section, in visual order.
    public var workspaces: [SidebarWorkspace] { nodes.flatMap(\.workspaces) }

    /// How many machine sections `sections` hold. With one, its header (when
    /// shown) is the list's "Projects" title, not the machine's, and draws
    /// no machine icon (`SidebarRow.titlesProjects`).
    public static func machineCount(_ sections: [SidebarSection]) -> Int {
        sections.reduce(0) { $0 + ($1.machine == nil ? 0 : 1) }
    }
}
