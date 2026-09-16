/// The newest terminal request's workspace-level presentation. In-flight
/// requests show nothing here: the reserved pane itself carries progress.
enum CloudPaneCreationPhase {
    case idle
    case failed(CloudPaneCreationFailure)
}
