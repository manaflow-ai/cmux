import SwiftUI

struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    /// A computer that can receive a new workspace from the shared list menu.
    struct ComputerTarget: Equatable, Identifiable {
        enum Kind: Equatable {
            case mac(macDeviceID: String, instanceTag: String?)
            case cloud(hostID: String)
        }

        let id: String
        let kind: Kind
        let name: String
        let isConnected: Bool
        let systemImage: String

        var statusColor: Color {
            isConnected ? .green : .secondary
        }
    }

    let canCreate: Bool
    let canCreateGroup: Bool
    /// Computers offered as create targets under All Computers. Empty when
    /// the list is scoped to one computer.
    var computerTargets: [ComputerTarget] = []

    var asksForComputer: Bool { computerTargets.count > 1 }
    var isEnabled: Bool { canCreate || computerTargets.contains(where: \.isConnected) }
}
