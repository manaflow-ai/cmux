import CMUXAgentLaunch

/// The durable admission result for one Codex restore request.
enum CodexRestoreValidationResult {
    case allowed(CodexSessionResumeEvidence)
    case missing
    case unavailable
    case rejectedChild(CodexSessionResumeEvidence)
    case bindingChanged
}
