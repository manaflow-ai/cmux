import CMUXAgentLaunch

/// An actionable state transition emitted by the in-process transcript monitor.
nonisolated enum CodexTranscriptMonitorUpdate: Sendable, Equatable {
    case userInput(CodexTranscriptMonitorUserInput)
    case failure(CodexTranscriptMonitorFailure)
}
