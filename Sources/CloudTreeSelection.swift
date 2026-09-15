import Foundation
import CmuxCloudMachines

/// Window-owned selection snapshot for the Machines tree and New Workspace routing.
struct CloudTreeSelection: Equatable {
    static let empty = CloudTreeSelection(nodeID: nil, machine: .none)

    /// Stable outline node identity, used to restore the visible selection.
    let nodeID: String?
    /// Complete machine context represented by that node.
    let machine: CloudWorkspaceMachineSelection
}
