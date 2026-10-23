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
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, Self.order) { _, activity in
            let outcome: Outcome = activity == .afterWaiting ? .missed : .committed
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { body(outcome) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
}
