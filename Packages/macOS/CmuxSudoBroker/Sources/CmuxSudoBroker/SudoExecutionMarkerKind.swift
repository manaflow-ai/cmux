/// Identifies a broker marker recognized in privileged-process output.
enum SudoExecutionMarkerKind: Sendable {
    case authentication
    case readiness
    case privilegedTimeout
    case privilegedCleanup
    case privilegedTransport
    case privilegedLaunch
}
