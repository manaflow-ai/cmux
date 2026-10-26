public import CmuxNextWakeups
import Darwin
public import Foundation

/// What the previous run left behind (`AppRunMarker`).
public nonisolated struct PreviousRun: Codable, Equatable, Sendable {
    public var pid: Int32
    public var launched: Date
    /// That run followed a crash or a quick kill
    /// (`LaunchRecovery.watchesForLoop`).
    public var recovery: Bool
    /// That run lived past `LaunchRecovery.quickCrashWindow`.
    public var survived: Bool
    /// The fatal signal the run's handler wrote, if any. Nil: the process
    /// ended without a handler running (SIGKILL, jetsam, power loss).
    public var signal: Int32?
    /// That run had begun a quit someone asked for (Quit, a quit request
    /// over the socket, SIGTERM, SIGINT, SIGHUP) when it ended. Nil in
    /// markers written before this field existed.
    public var quitting: Bool?
    /// The uncaught Objective-C exception that ended the run
    /// (`UncaughtExceptionRecorder`). Read from `run.exception`, never
    /// encoded into `run.json`.
    public var exception: RecordedException?
    /// Runs in a row before that one that ended before `startup_complete`
    /// (``StartupCrashStreak``). Nil in markers written before this field.
    public var unfinishedRuns: Int?
    /// That run reached `startup_complete`.
    public var reachedComplete: Bool?
    /// The startup task that run was in when its fatal signal came. Read
    /// from `run.signal`, never encoded into `run.json`.
    public var lastTask: String?

    public init(pid: Int32, launched: Date, recovery: Bool, survived: Bool, signal: Int32?, quitting: Bool? = nil,
                exception: RecordedException? = nil, unfinishedRuns: Int? = nil, reachedComplete: Bool? = nil) {
        self.pid = pid
        self.launched = launched
        self.recovery = recovery
        self.survived = survived
        self.signal = signal
        self.quitting = quitting
        self.exception = exception
        self.unfinishedRuns = unfinishedRuns
        self.reachedComplete = reachedComplete
    }

    private enum CodingKeys: String, CodingKey {
        case pid, launched, recovery, survived, signal, quitting, unfinishedRuns, reachedComplete
    }

    /// The run ended because someone asked it to: a requested-quit signal
    /// its handler recorded, or no fatal signal while a requested quit ran
    /// (killed before it finished). A fault during a quit is still a crash.
    public var endedAsAsked: Bool {
        if let signal { return LaunchRecovery.requestedQuitSignals.contains(signal) }
        return quitting == true
    }

    /// The run crashed: its fatal signal handler wrote the signal, or it
    /// ended on an uncaught exception. A run that ended with no handler
    /// running (`kill -9`, jetsam, power loss) did not crash; its next
    /// launch restores the same way, without the restart notice.
    public var crashed: Bool { signal != nil || exception != nil }
}

/// How this launch follows the previous one. Pure: `AppRunMarker` supplies
/// the inputs.
public nonisolated enum LaunchRecovery: Equatable, Sendable {
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
    public static let quickCrashWindow: Duration = .seconds(60)

    /// Signals that ask the app to quit (`kill`, Ctrl-C in the launching
    /// terminal, that terminal closing). `QuitSignal` turns them into Quit,
    /// keep sessions; ending on one is never a restart.
    public static let requestedQuitSignals: Set<Int32> = [SIGTERM, SIGINT, SIGHUP]

    public static func decide(previous: PreviousRun?) -> LaunchRecovery {
        guard let previous, !previous.endedAsAsked else { return .clean }
        if previous.recovery, !previous.survived { return .restartedSafely(previous) }
        return previous.crashed ? .restarted(previous) : .clean
    }

    /// Whether this launch watches for a restart loop: it follows a crash,
    /// or a run killed within `quickCrashWindow` of its launch (a hang at
    /// restore ends in Force Quit, which records no signal). If this run
    /// also ends early, the next launch restores without browser pages.
    public static func watchesForLoop(previous: PreviousRun?) -> Bool {
        if decide(previous: previous).isRestart { return true }
        guard let previous, !previous.endedAsAsked else { return false }
        return !previous.survived
    }

    /// The crash streak this launch starts with: the previous run's, one
    /// longer unless it reached `startup_complete`, lived past
    /// `quickCrashWindow` (longer than the startup failsafe) or ended as
    /// asked. A normal quit removes the marker, so it ends the streak too.
    public static func crashStreak(previous: PreviousRun?) -> StartupCrashStreak {
        guard let previous else { return StartupCrashStreak() }
        let finished = previous.reachedComplete == true || previous.survived || previous.endedAsAsked
        return StartupCrashStreak(unfinishedRuns: previous.unfinishedRuns ?? 0).next(finished: finished)
    }

    public var previous: PreviousRun? {
        switch self {
        case .clean: nil
        case .restarted(let run), .restartedSafely(let run): run
        }
    }

    public var isRestart: Bool { previous != nil }
    public var skipsBrowserPages: Bool {
        if case .restartedSafely = self { return true }
        return false
    }
}

/// An Objective-C exception that ended the previous run: what the
/// `run.exception` file holds (crash-elimination class b: NSRangeException,
/// unrecognized selector). Holds the exception's name, reason and call stack
/// frames only; the reason is AppKit's text and the frames are "image
/// function + offset" lines (`StackSymbolicator`).
public nonisolated struct RecordedException: Codable, Equatable, Sendable {
    public var name: String
    public var reason: String
    public var frames: [String]

    public init(name: String, reason: String, frames: [String]) {
        self.name = name
        self.reason = reason
        self.frames = frames
    }

    /// "NSRangeException: <reason>", trimmed to one line for the notice.
    public var summary: String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.isEmpty ? name : "\(name): \(line)"
        return text.count > 200 ? String(text.prefix(199)) + "…" : text
    }
}
