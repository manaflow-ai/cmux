import Foundation

extension CloudWorkspaceRenameService {
    enum BindingReconciliation: Equatable {
        case keep
        case clear
        case rebind(machine: SurfaceMachineID, remoteWorkspaceID: String)
    }
}
