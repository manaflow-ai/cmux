public import Foundation

/// Records terminal input liveness for agent-hibernation tracking.
///
/// Implemented in the app over `AgentHibernationController`; the recorder is
/// called synchronously on the main-actor input hot path and is responsible for
/// its own lock-free enablement gate.
public protocol AgentHibernationRecording: AnyObject, Sendable {
    /// Records that a terminal surface received input.
    ///
    /// - Parameters:
    ///   - workspaceId: The owning workspace id.
    ///   - panelId: The surface/panel id that received input.
    @MainActor
    func recordTerminalInput(workspaceId: UUID, panelId: UUID)
}
