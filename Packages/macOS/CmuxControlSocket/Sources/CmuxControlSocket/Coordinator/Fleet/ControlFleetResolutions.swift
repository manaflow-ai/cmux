public import Foundation

/// The outcome of `fleet.status`.
public enum ControlFleetStatusResolution: Sendable, Equatable {
    /// The status snapshot was read.
    case ok(ControlFleetStatusSnapshot)
    /// No Fleet exists for the requested identifier.
    case fleetNotFound(String)
}

/// The outcome of `fleet.create`.
public enum ControlFleetCreateResolution: Sendable, Equatable {
    /// The Fleet was created.
    case created(ControlFleetSnapshot)
    /// The requested configuration is invalid.
    case invalidConfiguration(reason: String)
    /// The Fleet engine is not linked into this app build.
    case engineUnavailable
}

/// The outcome of `fleet.start` and `fleet.stop`.
public enum ControlFleetLifecycleResolution: Sendable, Equatable {
    /// The lifecycle mutation succeeded.
    case ok(ControlFleetSnapshot)
    /// No Fleet exists for the requested identifier.
    case fleetNotFound(String)
    /// The Fleet engine is not linked into this app build.
    case engineUnavailable
}

/// The outcome of `fleet.task.add`.
public enum ControlFleetTaskAddResolution: Sendable, Equatable {
    /// The task was added.
    case added(ControlFleetTaskSnapshot)
    /// No Fleet exists for the requested identifier.
    case fleetNotFound(String)
    /// The Fleet engine is not linked into this app build.
    case engineUnavailable
}

/// The outcome of `fleet.task.list`.
public enum ControlFleetTaskListResolution: Sendable, Equatable {
    /// The task snapshots were read.
    case ok([ControlFleetTaskSnapshot])
    /// No Fleet exists for the requested identifier.
    case fleetNotFound(String)
}

/// The outcome of `fleet.task.retry` and `fleet.task.cancel`.
public enum ControlFleetTaskActionResolution: Sendable, Equatable {
    /// The task mutation succeeded.
    case ok(ControlFleetTaskSnapshot)
    /// No task exists for the requested identifier.
    case taskNotFound(String)
    /// The task cannot be mutated from its current state.
    case invalidState(current: ControlFleetTaskStateName)
    /// The Fleet engine is not linked into this app build.
    case engineUnavailable
}

/// The outcome of `fleet.task.open`.
public enum ControlFleetTaskOpenResolution: Sendable, Equatable {
    /// The task workspace was opened.
    case opened(workspaceID: UUID)
    /// No task exists for the requested identifier.
    case taskNotFound(String)
    /// The task has no workspace available yet.
    case workspaceUnavailable
    /// The Fleet engine is not linked into this app build.
    case engineUnavailable
}
