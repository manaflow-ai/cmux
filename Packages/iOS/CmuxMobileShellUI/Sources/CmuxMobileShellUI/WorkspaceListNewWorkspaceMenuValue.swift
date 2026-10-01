import CmuxMobileShell
import SwiftUI

struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    let canCreate: Bool
    let canCreateGroup: Bool
    /// Computers a new workspace can go to while "All Computers" is shown.
    /// With more than one, `+` asks which; otherwise it creates directly.
    var computerTargets: [WorkspaceCreateComputerTarget] = []
    /// When `+` creates on one SSH computer: the kinds it offers (PRD D31).
    /// Empty for a Mac, where `+` creates a workspace directly.
    var sshKinds: [WorkspaceCreateKindOption] = []
    /// The SSH computer `+` creates on. Part of the value because the menu
    /// is `Equatable` on its value alone: two hosts offer the same kinds,
    /// so without it switching hosts kept the previous host's create action
    /// and the first New Shell after a switch opened on the old host.
    var sshTargetHostID: UUID?

    var asksForComputer: Bool { computerTargets.count > 1 }
}

/// One computer offered by `+` under "All Computers": a connected Mac or a
/// saved SSH computer, with the status dot and text used elsewhere.
struct WorkspaceCreateComputerTarget: Equatable, Identifiable {
    enum Kind: Equatable {
        case mac(macDeviceID: String, instanceTag: String?)
        case ssh(UUID)
    }

    /// The computer's machine id in the workspace list's picker.
    let id: String
    let kind: Kind
    let name: String
    /// Shown under the name when the computer is not connected.
    let statusText: String?
    let statusColor: Color
    /// SSH computers: the kinds of workspace `+` can create there, shown as
    /// a submenu. Empty for Macs.
    var sshKinds: [WorkspaceCreateKindOption] = []
}

/// One "New …" item for an SSH computer: a cmux-tui workspace, a tmux
/// session, or a shell, dimmed with the reason when the computer cannot
/// create it.
struct WorkspaceCreateKindOption: Equatable, Identifiable {
    let kind: MobileSSHWorkspaceKind
    let unavailableReason: String?

    var id: MobileSSHWorkspaceKind { kind }

    init(_ availability: MobileSSHKindAvailability) {
        kind = availability.kind
        unavailableReason = availability.unavailableReason
    }
}
