public import Foundation

/// The workspace floating Dock slice of the control-command seam.
@MainActor
public protocol ControlWorkspaceFloatingDockContext: AnyObject {
    func controlWorkspaceFloatingDock(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        action: ControlWorkspaceFloatingDockAction
    ) -> ControlWorkspaceFloatingDockResolution

    /// Persists a managed floating-note mutation on the socket worker. The
    /// implementation may make short main-actor hops to resolve and commit UI
    /// state, but must not perform file I/O on the main actor.
    nonisolated func controlSetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String,
        text: String
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


    nonisolated func controlSetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String,
        text: String
    ) -> ControlWorkspaceFloatingDockResolution {
        .tabManagerUnavailable
    }
}
