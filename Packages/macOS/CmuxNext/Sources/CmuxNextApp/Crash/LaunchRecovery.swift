import Foundation

/// What the previous run left behind (`AppRunMarker`).
nonisolated struct PreviousRun: Codable, Equatable, Sendable {
    var pid: Int32
    var launched: Date
    /// That run itself was a restart after a problem.
    var recovery: Bool
    /// That run lived past `LaunchRecovery.quickCrashWindow`.
    var survived: Bool
    /// The fatal signal the run's handler wrote, if any. Nil: the process
    /// ended without a handler running (SIGKILL, jetsam, power loss).
    var signal: Int32?
}

/// How this launch follows the previous one. Pure: `AppRunMarker` supplies
/// the inputs.
nonisolated enum LaunchRecovery: Equatable, Sendable {
    /// The previous run quit normally (or was asked to: SIGTERM).
    case clean
    /// The previous run ended unexpectedly: restore everything and show the
    /// notice.
    case restarted(PreviousRun)
    /// The previous run was already a restart and ended again soon after it
    /// started: restore windows and terminals, but not browser pages, and
    /// say so (no restart loop through a page that kills the app).
    case restartedSafely(PreviousRun)

    /// A restart that ends within this time of its launch counts as quick.
    static let quickCrashWindow: Duration = .seconds(60)

    static func decide(previous: PreviousRun?) -> LaunchRecovery {
        guard let previous, previous.signal != SIGTERM else { return .clean }
        if previous.recovery, !previous.survived { return .restartedSafely(previous) }
        return .restarted(previous)
    }

    var previous: PreviousRun? {
        switch self {
        case .clean: nil
        case .restarted(let run), .restartedSafely(let run): run
        }
    }

    var isRestart: Bool { previous != nil }
    var skipsBrowserPages: Bool {
        if case .restartedSafely = self { return true }
        return false
    }
}
