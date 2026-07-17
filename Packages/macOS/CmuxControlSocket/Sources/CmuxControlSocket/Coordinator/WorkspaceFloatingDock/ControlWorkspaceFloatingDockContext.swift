public import Foundation

/// The workspace floating Dock slice of the control-command seam.
@MainActor
public protocol ControlWorkspaceFloatingDockContext: AnyObject {
    func controlWorkspaceFloatingDock(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        action: ControlWorkspaceFloatingDockAction
    ) -> ControlWorkspaceFloatingDockResolution
}

public extension ControlWorkspaceFloatingDockContext {
    func controlWorkspaceFloatingDock(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        action: ControlWorkspaceFloatingDockAction
    ) -> ControlWorkspaceFloatingDockResolution {
        .tabManagerUnavailable
    }
}
