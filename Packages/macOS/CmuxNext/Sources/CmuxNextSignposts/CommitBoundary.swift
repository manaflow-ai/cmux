import CmuxNextCompat
import CmuxNextTrace
public import CoreFoundation

/// Runs work once, right after the next Core Animation commit of the main run loop.
///
/// Core Animation commits the main thread's implicit transaction from a main run-loop observer
/// (`CA::Transaction::observer_callback`, before waiting and on exit) at order 2,000,000. A
/// one-shot observer at the next order runs after that commit: a real signal, no sleep, no
/// timer, nothing installed between calls. ``CommitBoundaryAudit`` reads the main run loop's
/// display, layout and commit observers (Core Animation's and AppKit's) and flags any that run
/// after this one, on whichever macOS runs it (tests, and the App's `debug.commit_boundary`).
///
/// What it measures: the end of the commit of what changed *synchronously* up to that turn's
/// commit. Work deferred to a later turn (a `Task` awaiting the daemon, Chromium's
/// `CreateBrowser`, an Observation update applied later, a frame client's next display frame)
/// commits later, so this is not "the frame that shows the result".
///
/// It can miss the turn's commit. CFRunLoop snapshots the observer list before each callout
/// pass, so a boundary asked for during a before-waiting callout (from Core Animation's own
/// layout pass or from another observer) only fires after the run loop slept and woke: it also
/// listens for the wake and then reports ``Outcome/missed``, so a reader drops the sample
/// instead of counting idle time. One asked for during an exit callout fires at the next turn's
/// commit and includes that turn's work; one asked for while the loop runs a mode outside the
/// common modes fires when a common mode runs again (Core Animation's observer is in the common
/// modes too, so nothing committed in between either).
///
/// A boundary writes no trace record of the commit: `frame.commit` is written once per turn's commit
/// by one repeating observer, however many boundaries wait on it (``FramePresentEstimate/observeCommits()``).
///
/// ```swift
/// let interval = Signposter.action.begin(.actionCommit, "id=tab.new")
/// CommitBoundary().after { Signposter.action.end(.actionCommit, interval, $0) }
/// ```
public struct CommitBoundary: Sendable {
    /// How the boundary fired.
    public enum Outcome: Sendable, Hashable {
        /// After the Core Animation commit that ended the turn (before waiting, or on exit).
        case committed
        /// After the run loop slept and woke: the turn's commit pass had begun before the
        /// boundary was installed, so the time includes idle time and is not a commit.
        case missed
    }

    /// One firing of the boundary: how it fired and when.
    public struct Commit: Sendable, Hashable {
        /// How the boundary fired.
        public let outcome: Outcome
        /// `CLOCK_UPTIME_RAW` nanoseconds when the boundary ran, right after the commit. It is the
        /// clock of `NSEvent.timestamp` and `CACurrentMediaTime`, so an input's latency and the
        /// display's vsync phase subtract from it directly.
        public let commitEndNanos: UInt64

        public init(outcome: Outcome, commitEndNanos: UInt64) {
            self.outcome = outcome
            self.commitEndNanos = commitEndNanos
        }
    }

    /// The observer order: one after Core Animation's commit observer.
    public static let order: CFIndex = 2_000_001

    /// A boundary on the main run loop.
    public init() {}

    /// Runs `body` once, after the Core Animation commit that ends this main run-loop turn.
    ///
    /// - Parameter body: Main-actor work; it runs in the same turn, before the run loop waits,
    ///   and gets ``Outcome/missed`` when the boundary first saw the run loop wake instead.
    @MainActor
    public func after(_ body: @escaping @MainActor (Outcome) -> Void) {
        afterCommit { body($0.outcome) }
    }

    /// Runs `body` once, after the Core Animation commit that ends this main run-loop turn, with
    /// the time the commit ended: the start of a presented estimate (CmuxNextWakeups'
    /// `PresentationClock.presented(commitEndNanos:on:_:)`, resolved by the next real vsync).
    ///
    /// - Parameter body: Main-actor work, as for ``after(_:)``.
    @MainActor
    public func afterCommit(_ body: @escaping @MainActor (Commit) -> Void) {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, Self.order) { _, activity in
            let commit = Commit(outcome: activity == .afterWaiting ? .missed : .committed,
                                commitEndNanos: TraceClock().nowNanos())
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { body(commit) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
}
