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

    /// Reads a managed floating note on the socket worker. Implementations
    /// keep disk I/O off the main actor and use short hops for model state.
    nonisolated func controlGetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String
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

    nonisolated func controlGetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String
    ) -> ControlWorkspaceFloatingDockResolution {
        .tabManagerUnavailable
    }
}
