/// Why startup completed, Chrome's `Startup.BrowserStartupCompleteReason`
/// (chrome/browser/after_startup_task_utils.cc). The cases are the plan's
/// (plans/cmux-next/chrome-parity/p08-startup.md, tasks 010 and 013); the
/// raw value names the `startup_complete.<reason>` launch mark.
public nonisolated enum StartupCompleteReason: String, CaseIterable, Sendable {
    case visiblePaneLoadedIdle
    case visiblePaneTimedOut
    case noVisiblePane
    case noWindow
    case daemonUnavailable
    case failsafe
}

/// The launch marks in the order they landed, each name once, with the marks
/// derived from them (the App's `DebugTimings` keeps one behind its lock).
///
/// ```swift
/// var log = LaunchMarkLog()
/// let recorded = log.record("first_terminal_frame", ms: 280) // and first_live_content_frame at 280
/// ```
public nonisolated struct LaunchMarkLog: Sendable {
    /// A launch mark: its name and milliseconds since process start.
    public struct Mark: Equatable, Sendable {
        public let name: String
        public let ms: Double

        public init(name: String, ms: Double) {
            self.name = name
            self.ms = ms
        }
    }

    /// A pane's first frame of its own live content in a visible window, not a saved picture:
    /// the terminal's first frame after the daemon's content reached its surface
    /// (`LaunchSettle`), a page's first paint in a shown pane (`first_page_frame`).
    /// The first of them is also `first_live_content_frame`, Chrome's
    /// `RecordFirstWebContentsNonEmptyPaint` (components/startup_metric_utils/browser/startup_metric_utils.h).
    public static let liveContentFrameMarks: Set<String> = ["first_terminal_frame", "first_page_frame"]
    public static let liveContentFrame = "first_live_content_frame"
    public static let startupComplete = "startup_complete"

    /// Every mark, in the order it was recorded.
    public private(set) var marks: [Mark] = []
    private var names: Set<String> = []

    public init() {}

    /// Whether `name` was recorded.
    public func contains(_ name: String) -> Bool { names.contains(name) }

    /// Records `name` at `ms` unless it was already. Returns what this call
    /// recorded: nothing for a repeat; else the mark, then
    /// `first_live_content_frame` when it is the first live content frame.
    public mutating func record(_ name: String, ms: Double) -> [Mark] {
        guard names.insert(name).inserted else { return [] }
        var recorded = [Mark(name: name, ms: ms)]
        if Self.liveContentFrameMarks.contains(name), names.insert(Self.liveContentFrame).inserted {
            recorded.append(Mark(name: Self.liveContentFrame, ms: ms))
        }
        marks.append(contentsOf: recorded)
        return recorded
    }

    /// Records `startup_complete` and, with the first completion only,
    /// `startup_complete.<reason>` at the same time.
    public mutating func recordStartupComplete(_ reason: StartupCompleteReason, ms: Double) -> [Mark] {
        let recorded = record(Self.startupComplete, ms: ms)
        guard !recorded.isEmpty else { return [] }
        return recorded + record("\(Self.startupComplete).\(reason.rawValue)", ms: ms)
    }
}
