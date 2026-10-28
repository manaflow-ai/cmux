import Foundation

/// What the previous run left behind (`AppRunMarker`).
nonisolated struct PreviousRun: Codable, Equatable, Sendable {
    var pid: Int32
    var launched: Date
    /// That run followed a crash or a quick kill
    /// (`LaunchRecovery.watchesForLoop`).
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
    /// The boot the run was in (`kern.bootsessionuuid` as hex); nil when unknown or in markers written before
    /// this field existed. A different boot at the next launch means the machine restarted after the run.
    var bootSession: String?
    /// The uncaught Objective-C exception that ended the run
    /// (`UncaughtExceptionRecorder`). Read from `run.exception`, never
    /// encoded into `run.json`.
    var exception: RecordedException?
    /// The run's kernel process start in Unix microseconds, as its black box and crash-key page headers say it:
    /// the next launch takes only that process's files. Nil when unknown or in markers
    /// written before this field existed.
    var processStart: UInt64?
    /// That run's startup completed (`StartupScheduler`'s completion). Nil in markers written before this field,
    /// which never count toward ``LaunchSafeMode``'s streak.
    var startupComplete: Bool?
    /// The last startup main task that run began before its startup completed (`debug.crashes`).
    var lastStartupTask: String?
    /// The runs in a row before that one that ended before their startup completed (``LaunchSafeMode``).
    var incompleteLaunches: Int?

    private enum CodingKeys: String, CodingKey {
        case pid, launched, recovery, survived, signal, quitting, bootSession, processStart, startupComplete, lastStartupTask,
             incompleteLaunches
    }

    /// The run ended because someone asked it to: a requested-quit signal
    /// its handler recorded, or no fatal signal while a requested quit ran
    /// (killed before it finished). A fault during a quit is still a crash.
    var endedAsAsked: Bool {
        if let signal { return LaunchRecovery.requestedQuitSignals.contains(signal) }
        return quitting == true
    }

    /// The run crashed: its fatal signal handler wrote the signal, or it
    /// ended on an uncaught exception. A run that ended with no handler
    /// running (`kill -9`, jetsam, power loss) did not crash; its next
    /// launch restores the same way, without the restart notice.
    var crashed: Bool { signal != nil || exception != nil }
}

/// How this launch follows the previous one. Pure: `AppRunMarker` supplies
/// the inputs.
nonisolated enum LaunchRecovery: Equatable, Sendable {
    /// The previous run quit normally, was asked to (a quit that had begun,
    /// or a requested-quit signal recorded before `QuitSignal` ran), or was
    /// killed with no handler running (`kill -9`, jetsam, power loss).
    case clean
    /// The previous run ended unexpectedly: restore everything and show the
    /// notice.
    case restarted(PreviousRun)
    /// The previous run followed a crash or a quick kill and ended again
    /// soon after it started: restore windows and terminals, but not browser pages, and
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
        return previous.crashed ? .restarted(previous) : .clean
    }

    /// Whether this launch watches for a restart loop: it follows a crash,
    /// or a run killed within `quickCrashWindow` of its launch (a hang at
    /// restore ends in Force Quit, which records no signal). If this run
    /// also ends early, the next launch restores without browser pages.
    static func watchesForLoop(previous: PreviousRun?) -> Bool {
        if decide(previous: previous).isRestart { return true }
        guard let previous, !previous.endedAsAsked else { return false }
        return !previous.survived
    }

    /// Whether the previous run adds one to the feature safe-mode crash
    /// streak (`FeatureSafeMode.launch`): it ended without a clean exit and
    /// no quit was asked for. Chrome counts every session whose clean-exit
    /// beacon was not written (components/metrics/clean_exit_beacon.cc)
    /// toward `variations_crash_streak`
    /// (components/variations/service/safe_seed_manager.cc). A run killed
    /// with no handler running counts too: Force Quit of a hang at launch
    /// records no signal.
    static func countsTowardCrashStreak(previous: PreviousRun?) -> Bool {
        guard let previous else { return false }
        return !previous.endedAsAsked
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
