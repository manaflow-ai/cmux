import SwiftUI

struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    let canCreate: Bool
    let canCreateGroup: Bool
    /// Computers offered as create targets under All Computers. Empty when
    /// the list is scoped to one computer.
    var computerTargets: [ComputerTarget] = []

    var asksForComputer: Bool { computerTargets.count > 1 }
    var isEnabled: Bool { canCreate || computerTargets.contains(where: \.isConnected) }
}
