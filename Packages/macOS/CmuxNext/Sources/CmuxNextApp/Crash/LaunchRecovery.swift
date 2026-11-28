import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextWindowRules
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
}

/// How this launch follows the previous one, asked of Rust (cmux-window-rules `launch_recovery`: a quit
/// as asked, a crash, a likely OOM kill, a restart loop). `AppRunMarker` supplies the inputs.
nonisolated struct LaunchRecovery: Equatable, Sendable {
    /// `clean`: quit, asked to, or killed with no OOM evidence. `restarted`: ended unexpectedly, restore
    /// and show the notice. `restartedSafely`: a restart loop, the pages that run started wait for Reload.
    nonisolated enum Kind: String, Decodable, Sendable { case clean, restarted, restartedSafely }

    private struct Plan: Decodable, Equatable, Sendable {
        var recovery: Kind, watchesForLoop: Bool, crashedPages: Set<String>, startsUpdaterBeforeWindows: Bool, likelyOom: Bool
    }

    private let plan: Plan
    /// The previous run, when this launch is a restart.
    let previous: PreviousRun?
    var kind: Kind { plan.recovery }
    /// This launch watches for a restart loop; if it also ends early, the next holds the pages it started.
    var watchesForLoop: Bool { plan.watchesForLoop }
    /// The restored tabs whose page stays unloaded until the person reloads it (after a restart loop).
    var crashedPages: Set<String> { plan.crashedPages }
    /// In a restart loop, once settings are read: not after a first frame the build may never reach.
    var startsUpdaterBeforeWindows: Bool { plan.startsUpdaterBeforeWindows }
    /// A signal-less, unrequested end after a high-footprint snapshot: likely an OOM kill.
    var likelyOOM: Bool { plan.likelyOom }
    var isRestart: Bool { kind != .clean }
    var isSafeRestart: Bool { kind == .restartedSafely }

    static let clean = LaunchRecovery(plan: Plan(recovery: .clean, watchesForLoop: false, crashedPages: [],
                                                 startsUpdaterBeforeWindows: false, likelyOom: false), previous: nil)

    /// A restart that ends within this time of its launch counts as quick.
    static let quickCrashWindow: Duration = .seconds(60)

    /// Signals that ask the app to quit (`kill`, Ctrl-C in the launching terminal, that terminal
    /// closing). `QuitSignal` turns them into Quit, keep sessions; ending on one is never a restart.
    static let requestedQuitSignals: Set<Int32> = [SIGTERM, SIGINT, SIGHUP]

    static func decide(previous: PreviousRun?) -> LaunchRecovery {
        struct Facts: Encodable {
            var recovery, survived, exception: Bool, signal: Int32?, quitting: Bool?, footprintMegabytes: Int?, startedPages: [String]?
        }
        struct Request: Encodable { var previous: Facts? }
        let facts = previous.map { Facts(recovery: $0.recovery, survived: $0.survived, exception: $0.exception != nil, signal: $0.signal,
                                         quitting: $0.quitting, footprintMegabytes: $0.context?.footprintMegabytes, startedPages: $0.startedPages) }
        guard let plan = WindowRules().call("window_launch_recovery", Request(previous: facts), as: Plan.self) else { return .clean }
        return LaunchRecovery(plan: plan, previous: plan.recovery == .clean ? nil : previous)
    }
}
