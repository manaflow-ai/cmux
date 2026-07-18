/// The app's current ownership decision for a monitored surface.
nonisolated enum CodexTranscriptMonitorOwnership: Sendable, Equatable {
    case alive(CodexTranscriptMonitorTarget)
    case gone
    case unknown
}
