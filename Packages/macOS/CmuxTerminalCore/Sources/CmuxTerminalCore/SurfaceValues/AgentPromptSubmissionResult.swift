public import Foundation

/// Definitive outcome of one addressed agent-prompt admission transaction.
public enum AgentPromptSubmissionResult: Equatable, Sendable {
    /// The complete prompt transaction was accepted by the target terminal.
    case submitted(workspaceID: UUID, surfaceID: UUID, queued: Bool)
    /// The request is retained until the human composer is safe to touch.
    case queued(workspaceID: UUID, surfaceID: UUID?, reason: String)
    /// Human-owned terminal-composer input was observed.
    case rejectedComposerBusy(workspaceID: UUID, surfaceID: UUID)
    /// The agent is in an active turn.
    case agentBusy(workspaceID: UUID, surfaceID: UUID)
    /// The agent process identity is not bound yet.
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
    /// No live surface exists and none can be started.
    case surfaceUnavailable(workspaceID: UUID, surfaceID: UUID)
    /// The target terminal process already exited.
    case processExited(workspaceID: UUID, surfaceID: UUID)
    /// The selected submit key could not be encoded.
    case invalidSubmitKey(workspaceID: UUID, surfaceID: UUID)
    /// The bounded app-owned queue cannot accept another request.
    case submissionQueueFull(workspaceID: UUID, surfaceID: UUID?)
    /// The prompt exceeds the bounded addressed-delivery payload budget.
    case promptTooLarge(workspaceID: UUID, surfaceID: UUID?, maximumBytes: Int)
}
