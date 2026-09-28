import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// One window's request to reveal the workspace its creation flow selected.
struct CloudWorkspaceCreationReveal: Equatable {
    let token: UUID
    var machine: SurfaceMachineID?
    var remoteWorkspaceID: String?
    var isWithdrawn = false

    /// The Cloud tree row, known once the daemon's receipt names the workspace.
    var nodeID: String? {
        guard let machine, let remoteWorkspaceID else { return nil }
        return CloudTreeNodeBuilder.nodeID(workspace: remoteWorkspaceID, machine: machine)
    }
}

/// The latest creation reveal per window, published to that window's Cloud tree.
@MainActor @Observable
final class CloudWorkspaceCreationReveals {
    func reveal(for manager: TabManager?) -> CloudWorkspaceCreationReveal? { nil }

    @discardableResult
    func begin(in manager: TabManager) -> UUID { UUID() }

    func receive(_ token: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String) {}

    func receive(_ token: UUID, revealing workspace: Workspace) {}

    func withdraw(_ token: UUID) {}
}
