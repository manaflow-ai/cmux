/// Payload-free state categories shared by the install-attempt coordinator and watchdog.
///
/// Keeping this mapping exhaustive in one place prevents lifecycle collaborators from silently
/// assigning contradictory meanings to the same ``UpdateState``.
enum UpdateAttemptDisposition {
    /// No update activity is visible.
    case idle
    /// Sparkle is requesting automatic-check permission.
    case permissionRequest
    /// A requested check is waiting for updater readiness or a prior cycle.
    case preparingCheck
    /// A foreground update check is running.
    case checking
    /// A concrete update is awaiting an install decision.
    case updateAvailable
    /// A fresh check completed normally without finding an update.
    case noUpdate
    /// A check or install surfaced a visible failure.
    case error
    /// An accepted update is waiting for Sparkle to begin its download.
    case startingDownload
    /// Download, extraction, or installation has visibly progressed.
    case installProgress
}

extension UpdateState {
    /// The shared semantic category used by install-attempt lifecycle policy.
    var attemptDisposition: UpdateAttemptDisposition {
        switch self {
        case .idle:
            .idle
        case .permissionRequest:
            .permissionRequest
        case .preparingCheck:
            .preparingCheck
        case .checking:
            .checking
        case .updateAvailable:
            .updateAvailable
        case .notFound:
            .noUpdate
        case .error:
            .error
        case .startingDownload:
            .startingDownload
        case .downloading, .extracting, .installing:
            .installProgress
        }
    }
}
