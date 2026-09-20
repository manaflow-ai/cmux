import CmuxMobileShellModel
import Foundation

/// Everything the "+" toolbar menu renders, as a value snapshot so the menu
/// never reads an `@Observable` store (see AGENTS.md list boundary).
struct MobileNewTerminalMenuValue: Equatable {
    /// A Mac the user can open a new terminal on.
    struct Host: Equatable, Identifiable {
        enum Status: Equatable {
            /// The phone's foreground connection targets this Mac.
            case connected
            /// The Mac heartbeats as online but is not the foreground connection.
            case online
            case offline
        }

        /// The pairing id, stable across the Computers screen and pickers.
        let id: String
        let macDeviceID: String
        let instanceTag: String?
        let name: String
        let status: Status
    }

    /// What one tap on the button does. Holding always opens the menu.
    enum PrimaryAction: Equatable {
        /// Create a workspace on the current foreground Mac.
        case createWorkspace
        /// Open the local Linux terminal on this iPhone.
        case openLocalLinux
        /// Start pairing a Mac.
        case addComputer
        /// Nothing can be opened; the button stays disabled.
        case none
    }

    /// Whether a workspace can be created on the foreground Mac right now.
    var canCreateWorkspace: Bool
    /// Whether the foreground Mac supports workspace groups.
    var canCreateWorkspaceGroup: Bool
    /// Every known Mac, connected first, then online, then offline.
    var hosts: [Host]
    /// Whether the local Linux runtime is bundled and can be opened.
    var isLocalLinuxAvailable: Bool
    /// Whether the pairing flow is reachable from this surface.
    var canAddComputer: Bool

    init(
        canCreateWorkspace: Bool = false,
        canCreateWorkspaceGroup: Bool = false,
        hosts: [Host] = [],
        isLocalLinuxAvailable: Bool = false,
        canAddComputer: Bool = false
    ) {
        self.canCreateWorkspace = canCreateWorkspace
        self.canCreateWorkspaceGroup = canCreateWorkspaceGroup
        self.hosts = hosts
        self.isLocalLinuxAvailable = isLocalLinuxAvailable
        self.canAddComputer = canAddComputer
    }

    /// The connected Mac keeps the historical one-tap "new workspace" gesture.
    /// Without one, a tap opens the local terminal, then falls back to pairing.
    var primaryAction: PrimaryAction {
        if canCreateWorkspace { return .createWorkspace }
        if isLocalLinuxAvailable { return .openLocalLinux }
        if canAddComputer { return .addComputer }
        return .none
    }

    /// The button is useful when a tap does something or the menu lists a
    /// host to open a terminal on.
    var isEnabled: Bool {
        primaryAction != .none || !hosts.isEmpty
    }

    /// Builds the host rows from the Computers-screen snapshots, dropping
    /// older duplicates of the same Mac and ordering by reachability.
    static func hosts(from computers: [MacComputerSnapshot]) -> [Host] {
        computers
            .filter { !$0.isOlderDuplicate }
            .map { computer in
                Host(
                    id: computer.id,
                    macDeviceID: computer.deviceId,
                    instanceTag: computer.instanceTag,
                    name: computer.title,
                    status: Self.status(for: computer)
                )
            }
            .sorted { lhs, rhs in
                let lhsRank = Self.rank(lhs.status)
                let rhsRank = Self.rank(rhs.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func status(for computer: MacComputerSnapshot) -> Host.Status {
        if computer.connectionStatus == .connected { return .connected }
        if case .online = computer.presence { return .online }
        return .offline
    }

    private static func rank(_ status: Host.Status) -> Int {
        switch status {
        case .connected: 0
        case .online: 1
        case .offline: 2
        }
    }
}
