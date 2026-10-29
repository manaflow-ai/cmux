public import Foundation

/// A failure to resolve the Simulator surface selected by control-socket routing.
public enum ControlSimulatorTargetFailure: Sendable, Equatable {
    /// No app window or tab manager is available.
    case tabManagerUnavailable
    /// The selected workspace does not exist.
    case workspaceNotFound
    /// The selected workspace mirrors a remote tmux session.
    case remoteWorkspace
    /// The selected surface does not exist.
    case surfaceNotFound(UUID?)
    /// The selected surface exists but is not a Simulator surface.
    case surfaceNotSimulator(UUID)
    /// No Simulator surface exists in the selected workspace.
    case simulatorNotFound
    /// More than one Simulator surface matches the request.
    case ambiguousSimulatorSurfaces(Int)
}
