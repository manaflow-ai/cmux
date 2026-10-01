enum CodexTranscriptFailureReadResult {
    case unavailable
    case pending
    case aborted
    case healthy(lastAssistantMessage: String?)
    case failure(CodexHookFailureCandidate)
}
