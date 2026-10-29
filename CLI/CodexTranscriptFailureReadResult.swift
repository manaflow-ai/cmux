enum CodexTranscriptFailureReadResult {
    case unavailable
    case pending
    case healthy(lastAssistantMessage: String?)
    case failure(CodexHookFailureCandidate)
}
