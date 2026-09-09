import CmuxTerminalCore

/// Result of resolving an agent terminal within the requested workspace.
@MainActor
enum AgentPromptTerminalTargetResolution {
    case success(AgentPromptTerminalTarget)
    case failure(AgentPromptSubmissionResult)
}
