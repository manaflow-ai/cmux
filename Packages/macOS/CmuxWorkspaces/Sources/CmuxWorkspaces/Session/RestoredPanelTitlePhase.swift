/// Lifecycle phases for restored terminal title admission.
enum RestoredPanelTitlePhase: Sendable {
    case awaitingInitialShellPrompt(internallySeededTitle: String?)
    case awaitingUserCommand
    case awaitingInternallySeededBootstrap(expectedTitle: String)
    case internallySeededBootstrapRunning(expectedTitle: String)
    case released
}
