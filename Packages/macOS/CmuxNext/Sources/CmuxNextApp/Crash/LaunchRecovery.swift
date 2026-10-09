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
    /// That run had begun a quit someone asked for (Quit, a quit request
    /// over the socket, SIGTERM, SIGINT, SIGHUP) when it ended. Nil in
    /// markers written before this field existed.
    var quitting: Bool?
    /// The uncaught Objective-C exception that ended the run
    /// (`UncaughtExceptionRecorder`). Read from `run.exception`, never
    /// encoded into `run.json`.
    var exception: RecordedException?

    private enum CodingKeys: String, CodingKey {
        case pid, launched, recovery, survived, signal, quitting
    }

    /// The run ended because someone asked it to: a requested-quit signal
    /// its handler recorded, or no fatal signal while a requested quit ran
    /// (killed before it finished). A fault during a quit is still a crash.
    var endedAsAsked: Bool {
        if let signal { return LaunchRecovery.requestedQuitSignals.contains(signal) }
        return quitting == true
    }
}

/// How this launch follows the previous one. Pure: `AppRunMarker` supplies
/// the inputs.
nonisolated enum LaunchRecovery: Equatable, Sendable {
    /// The previous run quit normally, or was asked to: a quit that had
    /// begun, or a requested-quit signal recorded before `QuitSignal` ran.
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

    /// Signals that ask the app to quit (`kill`, Ctrl-C in the launching
    /// terminal, that terminal closing). `QuitSignal` turns them into Quit,
    /// keep sessions; ending on one is never a restart.
    static let requestedQuitSignals: Set<Int32> = [SIGTERM, SIGINT, SIGHUP]

    static func decide(previous: PreviousRun?) -> LaunchRecovery {
        guard let previous, !previous.endedAsAsked else { return .clean }
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
