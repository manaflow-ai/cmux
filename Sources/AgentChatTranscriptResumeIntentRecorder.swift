import CmuxAgentChat

/// Bridges structured resume bindings into the live transcript registry.
struct AgentChatTranscriptResumeIntentRecorder: AgentChatResumeIntentRecording {
    @MainActor
    func record(_ intent: AgentChatResumeIntent) {
        AgentChatTranscriptService.recordResumeIntent(
            sessionID: intent.sessionID,
            source: intent.source,
            surfaceID: intent.surfaceID,
            workspaceID: intent.workspaceID,
            workingDirectory: intent.workingDirectory
        )
    }
}
