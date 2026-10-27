public import CmuxNextSettings

/// What the control socket reads of the main-thread watchdog: `debug.hangs` (its logs, frame and stall
/// counters and turn histograms, and their `clear`) and the quit's wedge seam (``QuitDeadline``). The
/// watchdog itself (`MainThreadWatchdog`, its run-loop observers, kqueue alarm and Mach stack sampler)
/// lives in CmuxNextControlDiagnostics, above this module, so Control names no Darwin-only diagnostics
/// type (plans/cmux-next/chrome-parity/p15-oracle.md section H, task 136). Chrome splits the same way:
/// `base/threading/hang_watcher.h` is the watcher, and its readers see only the histograms and crash keys.
///
/// Every member is read off the main actor (`debug.hangs` answers while the main thread is stalled), so
/// a conforming type reads atomics and lock-protected logs only.
public protocol MainThreadHangReporting: AnyObject, Sendable {
    /// Whether the watchdog is watching the main run loop.
    var isRunning: Bool { get }
    /// The stall threshold: a main-thread work gap this long is logged in ``log``.
    var stallThreshold: Duration { get }
    /// Main-thread stalls and busy windows.
    var log: HangLog { get }
    /// Scheduled tasks that ran past their class's per-frame budget.
    var overBudget: HangLog { get }
    /// Scheduled tasks still running past their class's hang deadline.
    var taskHangs: HangLog { get }
    /// Other threads' hang-watch scopes still open 2 s past their budget, with a stack.
    var threadHangs: HangLog { get }
    /// Other threads' hang-watch scopes past their budget, with no stack.
    var threadJanks: HangLog { get }
    /// Main-thread work gaps over 16.7 ms since the last reset, and the longest.
    var longFrameStats: (count: Int, max: Duration) { get }
    /// Main-thread work gaps over 8.3 ms since the last reset, and the longest gap of any length.
    var gapStats: (over120HzFrame: Int, max: Duration) { get }
    /// Work gaps of 100 ms and up and of 250 ms and up since start or the last reset.
    var stallCounts: StallCounts { get }
    /// Main run-loop wakes since start; never reset.
    var mainRunLoopWakes: UInt64 { get }
    /// `debug.hangs` `turn_histogram`: the main-turn and input-queueing histograms.
    var turnHistogramJSON: JSONValue { get }
    func resetLongFrames()
    func resetStallCounts()
    func resetTurnHistograms()
    /// A decided quit is ending: a hang is still reported but never fails the debug assertion.
    func endHangAssertions()
}
