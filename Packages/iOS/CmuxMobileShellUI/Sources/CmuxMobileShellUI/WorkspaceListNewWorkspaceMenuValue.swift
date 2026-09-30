import SwiftUI

struct WorkspaceListNewWorkspaceMenuValue: Equatable {
    let canCreate: Bool
    let canCreateGroup: Bool
    /// Computers offered as create targets under All Computers. Empty when
    /// the list is scoped to one computer.
    var computerTargets: [ComputerTarget] = []

    var asksForComputer: Bool { computerTargets.count > 1 }
    var singleConnectedTarget: ComputerTarget? {
        guard computerTargets.count == 1,
              let target = computerTargets.first,
              target.isConnected
        else {
            return nil
        }
        return target
    }
    var isEnabled: Bool { canCreate || computerTargets.contains(where: \.isConnected) }

    static func soleConnectedTarget(
        scopedExternalHostID: String?,
        targets: [ComputerTarget]
    ) -> ComputerTarget? {
        guard scopedExternalHostID == nil else { return nil }
        let connectedTargets = targets.filter(\.isConnected)
        guard connectedTargets.count == 1 else { return nil }
        return connectedTargets.first
    }
}
