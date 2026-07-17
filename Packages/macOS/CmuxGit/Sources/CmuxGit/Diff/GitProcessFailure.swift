enum GitProcessFailure: Sendable {
    case cancelled
    case timedOut
    case launchFailed
    case unsuccessfulExit
}
