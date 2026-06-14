enum AgentNeedsInputPublishResult: Equatable {
    case published(response: String)
    case duplicateSuppressed
    case targetUnavailable
}
