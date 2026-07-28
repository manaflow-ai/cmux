enum ApplicationSurfaceStopFailureAction: Equatable, Sendable {
    case retry
    case restartHelper
    case retainUntilHelperExit
}
