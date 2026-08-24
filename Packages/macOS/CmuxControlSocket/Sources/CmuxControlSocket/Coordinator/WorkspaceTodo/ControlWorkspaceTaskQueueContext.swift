public import Foundation

/// Read/dispatch seam for the cross-workspace task queue.
@MainActor
public protocol ControlWorkspaceTaskQueueContext: AnyObject {
    func controlWorkspaceTaskQueueList(
        statusRaw: String?,
        workspaceID: UUID?
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
        workspaceID: UUID?
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
