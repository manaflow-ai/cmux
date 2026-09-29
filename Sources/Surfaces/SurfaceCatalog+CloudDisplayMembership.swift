import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// The accepted daemon projection rows that describe VNC membership. This is
    /// derived at snapshot time so the tree never reads a local pane as remote
    /// authority.
    func cloudDisplayMemberships() -> [CloudVMDisplayMembership] {
        cloudStates.values
            .flatMap(\.displayMemberships)
            .sorted {
                ($0.machine.rawValue, $0.workspaceID, $0.displayID, $0.clientID, $0.viewID)
                    < ($1.machine.rawValue, $1.workspaceID, $1.displayID, $1.clientID, $1.viewID)
            }
    }
}
