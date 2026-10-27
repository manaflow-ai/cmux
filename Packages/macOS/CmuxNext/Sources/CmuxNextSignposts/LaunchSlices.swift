public import CmuxNextTrace

/// The five `launch.*` slices of one launch: each from the kernel's process start to its milestone, written to
/// the trace ring as one async slice (AB/AE) whose end carries the launch's temperature.
///
/// A slice is written when both its milestone and the temperature are known. The temperature is read at the
/// main run loop's start (``temperatureMark``), so the slices whose milestone comes first (process to main,
/// often the daemon handshake and the first window) wait for it, and the later ones are written at their
/// milestone. Like Chrome's startup spans (components/startup_metric_utils/common/startup_metric_utils.cc,
/// `EmitTraceEvent`), each is written whole, with the begin and end times it measured, on its own track.
///
/// A value: its owner keeps it under the lock of its launch marks (marks come from any thread) and writes the
/// returned slices outside the lock.
///
/// ```swift
/// var slices = LaunchSlices(processStartNanos: start.uptimeNanos)
/// let ready = slices.reach(.processToMain, atUptimeNanos: now) // nil: waits for the temperature
/// for slice in slices.sample(pageins: clock.pageins()) { slice.record(into: .shared) }
/// ```
public nonisolated struct LaunchSlices: Sendable {
    /// The launch mark at which the temperature is read: the end of `applicationDidFinishLaunching`, after which
    /// `NSApplication.run` turns the main run loop for the first time. It is Chrome's message-loop start
    /// (`RecordBrowserMainMessageLoopStart`, after the browser's main-thread setup, before its loop runs).
    public static let temperatureMark = "did_finish_launching_end"
    /// The launch mark of an interrupted launch, sent before the first window's frame: a hidden or windowless
    /// launch (`StartupPhase.Presentation`), where no one waits for a frame and the first window may open
    /// minutes later. It is Chrome's `WasMainWindowStartupInterrupted`: `ShouldLogStartupHistogram` then
    /// records no startup duration (components/startup_metric_utils/browser/startup_metric_utils.cc), and
    /// the bench reads the same mark (scripts/cmux-next/bench-startup.py `INTERRUPTED`).
    public static let interruptedMark = "launch.interrupted"

    /// A milestone a `launch.*` slice ends at.
    public nonisolated enum Milestone: Sendable, Hashable, CaseIterable {
        /// The first line of `main` (`main_start`).
        case processToMain
        /// The first window ordered front (`first_window_presented`).
        case firstWindow
        /// The first window's first committed frame (`first_window_frame_committed`).
        case firstFrame
        /// The daemon connection's handshake (`daemon.handshake_end`).
        case daemonReady
        /// The first terminal's first output (`first_terminal_content`: its replay, output or snapshot).
        case firstTerminalOutput

        /// The milestone launch mark `mark` reaches, or nil. A `switch`: it runs for every launch mark.
        public init?(mark: String) {
            switch mark {
            case "main_start": self = .processToMain
            case "first_window_presented": self = .firstWindow
            case "first_window_frame_committed": self = .firstFrame
            case "daemon.handshake_end": self = .daemonReady
            case "first_terminal_content": self = .firstTerminalOutput
            default: return nil
            }
        }

        /// The slice's catalog name.
        public var name: SignpostName {
            switch self {
            case .processToMain: SignpostName.launchProcessToMain
            case .firstWindow: SignpostName.launchFirstWindow
            case .firstFrame: SignpostName.launchFirstFrame
            case .daemonReady: SignpostName.launchDaemonReady
            case .firstTerminalOutput: SignpostName.launchFirstTerminalOutput
            }
        }
    }

    /// One whole slice, ready to write.
    public nonisolated struct Slice: Sendable, Equatable {
        /// The slice's catalog name.
        public let name: SignpostName
        /// The process start on the trace clock (never after ``endNanos``).
        public let beginNanos: UInt64
        /// The milestone on the trace clock.
        public let endNanos: UInt64
        /// The launch's temperature, in the end record's `arg0`.
        public let temperature: LaunchClock.Temperature

        /// The async id: "cmux" in the high half and the name's id, one track per name (Chrome keys each startup
        /// span's track by its name), never an id `makeSignpostID` hands out.
        public var asyncID: UInt64 { 0x636D_7578_0000_0000 | UInt64(name.rawValue) }

        /// Writes the slice into `runtime`'s ring while the launch category is on. The begin is marked estimated:
        /// it is the kernel's wall-clock start moved onto the trace clock, not a trace-clock read.
        ///
        /// - Returns: Whether it was written.
        @discardableResult
        public func record(into runtime: TraceRuntime) -> Bool {
            runtime.writeAsyncSlice(name: name.rawValue, categoryBit: name.traceCategory.traceBit, id: asyncID,
                                    beginNanos: beginNanos, endNanos: endNanos, beginFlags: .estimated,
                                    endArg0: UInt64(temperature.rawValue))
        }
    }

    /// The process start on the trace clock.
    public let processStartNanos: UInt64
    /// The launch's temperature, nil until ``sample(pageins:)``.
    public private(set) var temperature: LaunchClock.Temperature?
    /// The page-ins the temperature was read from, nil until then or when they could not be read.
    public private(set) var pageins: UInt64?
    /// Whether the launch was interrupted (``interruptedMark``): nobody waited for its first frame, so its
    /// duration histograms take no sample. Its slices are still written.
    public private(set) var interrupted = false
    /// The milestones reached so far.
    private var reached: Set<Milestone> = []
    /// The milestones reached before the temperature, with their times.
    private var waiting: [(milestone: Milestone, endNanos: UInt64)] = []

    /// - Parameter processStartNanos: The process start on the trace clock (``LaunchClock/processStart()``).
    public init(processStartNanos: UInt64) {
        self.processStartNanos = processStartNanos
    }

    /// Records that `milestone` was reached at `endNanos`.
    ///
    /// - Returns: Its slice when the temperature is known; nil while it waits for the temperature or when the
    ///   milestone was reached before.
    public mutating func reach(_ milestone: Milestone, atUptimeNanos endNanos: UInt64) -> Slice? {
        guard reached.insert(milestone).inserted else { return nil }
        guard let temperature else {
            waiting.append((milestone: milestone, endNanos: endNanos))
            return nil
        }
        return slice(milestone, endNanos: endNanos, temperature: temperature)
    }

    /// Decides the launch's temperature from `pageins` (nil: unreadable), once.
    ///
    /// - Returns: The slices that waited for it, in the order their milestones came; empty after the first call.
    public mutating func sample(pageins: UInt64?) -> [Slice] {
        guard temperature == nil else { return [] }
        let temperature = LaunchClock.Temperature(pageins: pageins)
        self.temperature = temperature
        self.pageins = pageins
        defer { waiting = [] }
        return waiting.map { slice($0.milestone, endNanos: $0.endNanos, temperature: temperature) }
    }

    /// Marks the launch interrupted (``interruptedMark``), for good.
    public mutating func interrupt() {
        interrupted = true
    }

    private func slice(_ milestone: Milestone, endNanos: UInt64, temperature: LaunchClock.Temperature) -> Slice {
        Slice(name: milestone.name, beginNanos: min(processStartNanos, endNanos), endNanos: endNanos, temperature: temperature)
    }
}
