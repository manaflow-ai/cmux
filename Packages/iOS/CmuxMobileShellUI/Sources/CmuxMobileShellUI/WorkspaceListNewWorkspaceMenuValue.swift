import SwiftUI

struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    let canCreate: Bool
    let canCreateGroup: Bool
    /// Computers a new workspace can go to while "All Computers" is shown.
    /// With more than one, `+` asks which; otherwise it creates directly.
    var computerTargets: [WorkspaceCreateComputerTarget] = []

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
}
