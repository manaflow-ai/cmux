/// The newest terminal request's non-blocking workspace presentation.
enum CloudPaneCreationPhase {
    case idle
    case starting
    case failed(CloudPaneCreationFailure)
}
