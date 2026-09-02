public import Foundation

/// Read/dispatch seam for the cross-workspace task queue.
@MainActor
public protocol ControlWorkspaceTaskQueueContext: AnyObject {
    /// Localized response strings resolved by the application composition root.
    var controlWorkspaceTaskQueueStrings: ControlWorkspaceTaskQueueStrings { get }

    /// Reads queue rows using the requested scope and presentation order.
    ///
    /// - Parameters:
    ///   - statusRaw: Optional lifecycle-state filter.
    ///   - workspaceID: Optional source-workspace filter.
    ///   - windowID: Optional owning-window filter.
    func controlWorkspaceTaskQueueList(
        statusRaw: String?,
        workspaceID: UUID?,
        windowID: UUID?
    ) -> ControlWorkspaceTaskQueueResolution

    func controlWorkspaceTaskQueueDispatch(
        itemID: UUID,
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceTaskQueueDispatchResolution

    func controlWorkspaceTaskQueueReveal(
        itemID: UUID
    ) -> ControlWorkspaceTaskQueueRevealResolution

    func controlWorkspaceTaskQueueSetTarget(
        itemID: UUID,
        workingDirectory: String?,
        agentCommand: String?,
        agentName: String?
    ) -> ControlWorkspaceTaskQueueTargetResolution
}

/// Queue methods are optional for existing test seams and staged app owners.
/// The default is an unavailable response until the app conformance supplies
/// the live workspace projection.
public extension ControlWorkspaceTaskQueueContext {
    func controlWorkspaceTaskQueueList(
        statusRaw: String?,
        workspaceID: UUID?,
        windowID: UUID?
    ) -> ControlWorkspaceTaskQueueResolution {
        .tabManagerUnavailable
    }

    func controlWorkspaceTaskQueueDispatch(
        itemID: UUID,
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceTaskQueueDispatchResolution {
        .tabManagerUnavailable
    }

    func controlWorkspaceTaskQueueReveal(
        itemID: UUID
    ) -> ControlWorkspaceTaskQueueRevealResolution {
        .tabManagerUnavailable
    }

    func controlWorkspaceTaskQueueSetTarget(
        itemID: UUID,
        workingDirectory: String?,
        agentCommand: String?,
        agentName: String?
    ) -> ControlWorkspaceTaskQueueTargetResolution {
        .tabManagerUnavailable
    }
}
