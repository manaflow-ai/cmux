import CmuxNextCrashReporting
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
    /// The uncaught Objective-C exception that ended the run
    /// (`UncaughtExceptionRecorder`). Read from `run.exception`, never
    /// encoded into `run.json`.
    var exception: RecordedException?
    /// Restored browser tabs whose page that run started before it lived past
    /// `LaunchRecovery.quickCrashWindow` (`AppRunMarker.notePageStarted`). Nil in
    /// markers written before this field existed.
    var startedPages: [String]?
    /// What the run was doing shortly before it ended (`CrashContextRecorder`).
    /// Nil in markers written before this field existed, and before the first snapshot.
    var context: CrashContext?
    /// That run's version (`CFBundleShortVersionString CFBundleVersion`) and commit (`CMUXCommit`):
    /// an update may install between the crash and the report. Nil in older markers.
    var version: String?
    var commit: String?

    private enum CodingKeys: String, CodingKey {
        case pid, launched, recovery, survived, signal, quitting, startedPages, context, version, commit
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
    /// soon after it started: restore everything, except that a page that run
    /// started before it ended waits for Reload (`crashedPages`), so a page that
    /// kills the app cannot loop.
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
    /// also ends early, the next launch holds the pages it started (`crashedPages`).
    static func watchesForLoop(previous: PreviousRun?) -> Bool {
        if decide(previous: previous).isRestart { return true }
        guard let previous, !previous.endedAsAsked else { return false }
        return !previous.survived
    }

    var previous: PreviousRun? {
        switch self {
        case .clean: nil
        case .restarted(let run), .restartedSafely(let run): run
        }
    }

    var isRestart: Bool { previous != nil }

    /// This launch follows a restart loop (`restartedSafely`).
    var isSafeRestart: Bool {
        if case .restartedSafely = self { return true }
        return false
    }

    /// The restored tabs whose page stays unloaded until the person reloads it: after a restart
    /// loop, the pages the quick-ending run had started (one of them may be what ended it).
    /// Every other tab loads when it shows, as after any launch.
    var crashedPages: Set<String> {
        guard case .restartedSafely(let run) = self else { return [] }
        return Set(run.startedPages ?? [])
    }
}
