public import Foundation

/// Records terminal input liveness for agent-hibernation tracking.
///
/// Implemented in the app over `AgentHibernationController`; the recorder is
/// called synchronously on the input hot path and is responsible for its own
/// enablement gate and main-actor hop, exactly like the legacy
/// `recordAgentHibernationTerminalInput` helper it replaces.
public protocol AgentHibernationRecording: AnyObject, Sendable {
    /// Records that a terminal surface received input.
    ///
    /// - Parameters:
    ///   - workspaceId: The owning workspace id.
    ///   - panelId: The surface/panel id that received input.
    func recordTerminalInput(workspaceId: UUID, panelId: UUID)
}
