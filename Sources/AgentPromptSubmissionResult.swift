import Foundation

/// Definitive outcome for one app-owned agent prompt transaction.
nonisolated enum AgentPromptSubmissionResult: Equatable, Sendable {
    /// The whole transaction was accepted for a resolved terminal.
    case submitted(workspaceID: UUID, surfaceID: UUID, queued: Bool)
    /// Human-owned composer input was preserved and blocked the transaction.
    case rejectedComposerBusy(workspaceID: UUID, surfaceID: UUID)
    /// The agent process identity is not bound to the composer yet.
    case agentScopeUnavailable(workspaceID: UUID, surfaceID: UUID)
    /// No workspace exists for the requested identifier.
    case workspaceNotFound(workspaceID: UUID)
    /// The explicit surface does not belong to the workspace.
    case surfaceNotFound(workspaceID: UUID, surfaceID: UUID)
    /// No recognized agent exists at the requested target.
    case agentNotFound(workspaceID: UUID, requestedSurfaceID: UUID?)
    /// More than one recognized agent requires an explicit surface.
    case ambiguousAgent(workspaceID: UUID, surfaceIDs: [UUID])
    /// The cold surface's pending-input budget is full.
    case inputQueueFull(workspaceID: UUID, surfaceID: UUID)
    /// No live surface exists and no cold surface can be started.
    case surfaceUnavailable(workspaceID: UUID, surfaceID: UUID)
    /// The target terminal process already exited.
    case processExited(workspaceID: UUID, surfaceID: UUID)
    /// The selected agent submit key could not be encoded.
    case invalidSubmitKey(workspaceID: UUID, surfaceID: UUID)
}
