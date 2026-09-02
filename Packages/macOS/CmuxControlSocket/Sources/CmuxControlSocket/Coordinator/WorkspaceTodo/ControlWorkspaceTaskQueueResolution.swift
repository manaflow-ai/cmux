public import Foundation

/// Result of reading the cross-workspace task queue.
public enum ControlWorkspaceTaskQueueResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case resolved([ControlWorkspaceTaskQueueItem])
}

/// Result of dispatching one queue row.
public enum ControlWorkspaceTaskQueueDispatchResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case notFound
    case notDispatchable
    case created(item: ControlWorkspaceTaskQueueItem, createdWorkspaceID: UUID, windowID: UUID?)
}

/// Result of revealing one queue row without changing selection or focus.
public enum ControlWorkspaceTaskQueueRevealResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case notFound
    case revealed(item: ControlWorkspaceTaskQueueItem)
}

/// Result of attaching or clearing a dispatch target on a queue row.
public enum ControlWorkspaceTaskQueueTargetResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case notFound
    case updated(ControlWorkspaceTaskQueueItem)
}
