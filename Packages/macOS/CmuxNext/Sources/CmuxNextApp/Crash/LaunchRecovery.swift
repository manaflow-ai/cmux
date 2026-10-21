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
    /// The out-of-process watcher ended the run (`run.watch`, cmux-tui
    /// `app_watch.rs`): a crash that did not finish, or a main thread hung
    /// past the limit. Never encoded into `run.json`.
    var watchEnding: WatchEnding?

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

    /// The run crashed: its fatal signal handler wrote the signal, or it
    /// ended on an uncaught exception. A run that ended with no handler
    /// running (`kill -9`, jetsam, power loss) did not crash; its next
    /// launch restores the same way, without the restart notice.
    var crashed: Bool { signal != nil || exception != nil || watchEnding != nil }
}

/// Why the app's watcher (`AppWatcher`) ended a run: `run.watch`.
nonisolated struct WatchEnding: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// A crash began and the process still ran after the crash grace.
        case crashStuck = "crash_stuck"
        /// The main thread stayed hung past the hang limit.
        case hang
    }

    var pid: Int32
    var reason: Reason
    /// How long the crash or hang had lasted when the watcher acted.
    var seconds: Int

    /// The ending `file` records for the run with `pid`, if any.
    static func read(_ file: URL, pid: Int32) -> WatchEnding? {
        // concurrency-allow: once at launch before the first window, a file of about 80 bytes.
        guard let data = try? Data(contentsOf: file),
              let ending = try? JSONDecoder().decode(WatchEnding.self, from: data), ending.pid == pid else { return nil }
        return ending
    }
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
