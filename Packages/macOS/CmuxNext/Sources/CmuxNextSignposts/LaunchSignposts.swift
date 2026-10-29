public import os

/// Always-on launch signposts (category ``SignpostCategory/launch``, Debug and Release): one point event
/// per launch mark and the launch phase intervals, so `log stream --signpost --predicate 'category ==
/// "launch"'` or an Instruments recording sees the same milestones as scripts/cmux-next/bench-startup.py.
///
/// Like Chrome's startup milestones (components/startup_metric_utils/browser/startup_metric_utils.cc),
/// which are trace events of the always-registered `startup` category, the phases are derived from
/// the milestone marks the app already records: an ``Interval`` begins at one mark and ends at another.
/// The app records each mark once per process, so each interval has exactly one begin and one end.
///
/// The intervals carry a fixed signpost id each, so the end needs no stored state and no lock; the
/// mark event's text is formatted by the log system only when something reads it.
///
/// ```swift
/// let signposts = LaunchSignposts()
/// signposts.mark("main_start", ms: 41.2)
/// ```
public nonisolated struct LaunchSignposts: Sendable {
    /// A launch phase, from its begin mark to its end mark.
    public enum Interval: UInt64, Sendable, CaseIterable {
        /// `main_start` to `main.run`: `CmuxNextApp.main` up to `NSApplication.run`.
        case main = 1
        /// `did_finish_launching_start` to `did_finish_launching_end`: `applicationDidFinishLaunching`.
        case didFinishLaunching = 2
        /// `dfl.theme` to `dfl.services`: `AppServices.init` and its adoption (watchdog reporting, reveal
        /// marks, Debug Settings).
        case appServices = 3
        /// `dfl.home_history` to `dfl.windows`: the first window built (`WindowManager.restoreWhenLoaded`).
        case windowBuild = 4
        /// `dfl.windows` to `first_window_frame_committed`: the built window to its first committed frame.
        case firstCommit = 5
        /// `crash.sentry_start` to `crash.sentry_started`: `SentrySDK.start` on main.
        case sentryStart = 6

        /// The interval's signpost name.
        public var name: StaticString {
            switch self {
            case .main: "launch.main"
            case .didFinishLaunching: "launch.did_finish_launching"
            case .appServices: "launch.app_services"
            case .windowBuild: "launch.window_build"
            case .firstCommit: "launch.first_commit"
            case .sentryStart: "launch.sentry_start"
            }
        }

        /// The launch mark that begins the interval.
        public var beginMark: String {
            switch self {
            case .main: "main_start"
            case .didFinishLaunching: "did_finish_launching_start"
            case .appServices: "dfl.theme"
            case .windowBuild: "dfl.home_history"
            case .firstCommit: "dfl.windows"
            case .sentryStart: "crash.sentry_start"
            }
        }

        /// The launch mark that ends the interval.
        public var endMark: String {
            switch self {
            case .main: "main.run"
            case .didFinishLaunching: "did_finish_launching_end"
            case .appServices: "dfl.services"
            case .windowBuild: "dfl.windows"
            case .firstCommit: "first_window_frame_committed"
            case .sentryStart: "crash.sentry_started"
            }
        }

        /// The fixed signpost id: "cmux" in the high half, so it never meets an id `makeSignpostID` hands out
        /// for a short-lived interval of the same category.
        var signpostID: OSSignpostID { OSSignpostID(0x636D_7578_0000_0000 | rawValue) }

        /// The intervals `mark` ends and begins (a mark may end one phase and begin the next).
        ///
        /// A `switch`, not a walk over `allCases`: it runs for every launch mark and builds no array.
        public static func boundary(at mark: String) -> (ends: Interval?, begins: Interval?) {
            switch mark {
            case "main_start": (nil, .main)
            case "main.run": (.main, nil)
            case "did_finish_launching_start": (nil, .didFinishLaunching)
            case "did_finish_launching_end": (.didFinishLaunching, nil)
            case "dfl.theme": (nil, .appServices)
            case "dfl.services": (.appServices, nil)
            case "dfl.home_history": (nil, .windowBuild)
            case "dfl.windows": (.windowBuild, .firstCommit)
            case "first_window_frame_committed": (.firstCommit, nil)
            case "crash.sentry_start": (nil, .sentryStart)
            case "crash.sentry_started": (.sentryStart, nil)
            default: (nil, nil)
            }
        }
    }

    /// A one-time native library call of the launch, timed where it runs: no launch mark bounds it, because
    /// it runs in a module below the app's mark sink. Like ``Interval``, each step has a fixed
    /// signpost id and runs once per process, so it has one begin and one end.
    public enum Step: UInt64, Sendable, CaseIterable {
        /// `ghostty_init` (`GhosttyRuntime.initializeLibrary`), in `main` before any other thread starts.
        case ghosttyInit = 32
        /// `ghostty_app_new` (`GhosttyRuntime.start(with:)`): libghostty's app, its render device and its two
        /// detached warm-up threads (font discovery, Metal), before the first window.
        case ghosttyAppNew = 33
        /// The first `ghostty_surface_new` (`TerminalFirstSurfaceSplit`): the font grid, the
        /// renderer and its thread of the first terminal, on main.
        case firstSurfaceNew = 34
        /// The terminal's launch prefetch (`TerminalLaunchPrefetch`): the Metal device and the
        /// terminal's fonts, on their own launch thread.
        case terminalPrefetch = 35

        /// The step's signpost name.
        public var name: StaticString {
            switch self {
            case .ghosttyInit: "launch.ghostty_init"
            case .ghosttyAppNew: "launch.ghostty_app_new"
            case .firstSurfaceNew: "launch.first_surface_new"
            case .terminalPrefetch: "launch.terminal_prefetch"
            }
        }

        /// The fixed signpost id, in the same "cmux" space as ``Interval``'s, above its raw values.
        var signpostID: OSSignpostID { OSSignpostID(0x636D_7578_0000_0000 | rawValue) }
    }

    private let signposter: OSSignposter

    /// Runs `body` inside `step`'s interval and returns its result.
    public func measure<Result>(_ step: Step, _ body: () throws -> Result) rethrows -> Result {
        begin(step)
        defer { end(step) }
        return try body()
    }

    /// Begins `step`'s interval; ``end(_:)`` ends it (the fixed id needs no state between the two).
    public func begin(_ step: Step) {
        _ = signposter.beginInterval(step.name, id: step.signpostID)
    }

    /// Ends the interval ``begin(_:)`` began for `step`.
    public func end(_ step: Step) {
        signposter.endInterval(step.name, .beginState(id: step.signpostID))
    }

    /// Launch signposts under ``SignpostCategory/subsystem``, category ``SignpostCategory/launch``.
    public init() {
        signposter = OSSignposter(subsystem: SignpostCategory.subsystem, category: SignpostCategory.launch.rawValue)
    }

    /// Emits the `launch.mark` event for the launch mark `name` and ends and begins the intervals it bounds.
    ///
    /// - Parameters:
    ///   - name: The launch mark, recorded once per process (`DebugTimings.markLaunch`).
    ///   - ms: The mark's time since process start; it can be earlier than the event's own timestamp when the
    ///     mark was taken on another thread before it was handed over.
    public func mark(_ name: String, ms: Double) {
        signposter.emitEvent("launch.mark", "\(name, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
        let boundary = Interval.boundary(at: name)
        if let ended = boundary.ends {
            signposter.endInterval(ended.name, .beginState(id: ended.signpostID))
        }
        if let begun = boundary.begins {
            _ = signposter.beginInterval(begun.name, id: begun.signpostID)
        }
    }

    /// Emits the `launch.value` event for a launch value: a count or a CPU time, never a time since process start,
    /// so it is not a `launch.mark` (scripts/cmux-next/trace.py places every `launch.mark` on the launch timeline).
    ///
    /// - Parameters:
    ///   - name: The value's name (`launch.pageins_first_frame`, `launch.main_cpu_ms`).
    ///   - number: The value.
    public func value(_ name: String, number: Double) {
        signposter.emitEvent("launch.value", "\(name, privacy: .public) value=\(number, format: .fixed(precision: 1), privacy: .public)")
    }
}
