/// Result of resolving an agent terminal within the requested workspace.
enum AgentPromptTerminalTargetResolution {
    case success(AgentPromptTerminalTarget)
    case failure(AgentPromptSubmissionResult)
}
