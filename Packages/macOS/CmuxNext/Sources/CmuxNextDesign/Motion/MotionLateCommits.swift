import CoreFoundation
import QuartzCore
public import CmuxNextWakeups
import CmuxNextSignposts

/// Counts the main thread's Core Animation commits that miss their frame while a Motion animation runs
/// (``MotionInFlight``), in Debug and Release: the `motion.late_commits` signpost, one event per late commit.
///
/// A commit is late when it ends after the vsync that ends the frame its run-loop turn began in: what it changed is
/// shown a frame later than the turn could have shown it. Chrome counts the same miss for its main frames
/// (`FrameSequenceTracker`'s "main thread missed the deadline" and `DroppedFrameCounter`,
/// cc/metrics/frame_sequence_tracker.cc, cc/metrics/dropped_frame_counter.cc).
///
/// The vsync grid comes from the newest display-link frame the display clock delivered
/// (`DisplayClock.newestFrame()`): the counter starts no display link and no ``FrameClient``, so it never adds a
/// frame wakeup. A commit with no tick under ``DisplayFrameSample/maxPhaseAge`` is not judged (``unjudgedCount``).
///
/// One main run-loop observer, one order after Core Animation's commit, sees each turn wake and each commit end.
/// With no animation running a callout reads only whether one runs (no clock, no record), and a sleeping run loop
/// makes none, so an idle app pays nothing. A turn starts when the run loop wakes, or where the previous commit
/// ended when it did not sleep; the turn an animation starts in is not judged (its start came before the motion).
/// The composition root makes one counter and keeps it.
public final class MotionLateCommits {
    /// The observer's order: one after Core Animation's commit observer (``CommitBoundary/order``).
    static let order: CFIndex = CommitBoundary.order

    /// Commits that ended after their frame's vsync.
    public private(set) var lateCount: UInt64 = 0
    /// Commits placed on a vsync grid (late or not).
    public private(set) var judgedCount: UInt64 = 0
    /// Commits made during motion with no turn start or no recent tick to place them on.
    public private(set) var unjudgedCount: UInt64 = 0

    private let newestFrame: @MainActor () -> DisplayFrameSample?
    private let isAnimating: @MainActor () -> Bool
    private let now: @MainActor () -> CFTimeInterval
    private let record: @MainActor (_ lateMilliseconds: Double, _ turnMilliseconds: Double) -> Void
    private var observer: CFRunLoopObserver?
    private var turnStart: CFTimeInterval?

    /// The app's counter, watching the main run loop from now on: ``MotionInFlight``'s animations, the vsync grid
    /// `newestFrame` reads (the app's `DisplayClock.newestFrame()`), and the `motion.late_commits` signpost.
    ///
    /// - Parameter newestFrame: The newest display-link frame (read only; it must start no link).
    public convenience init(newestFrame: @escaping @MainActor () -> DisplayFrameSample?) {
        self.init(newestFrame: newestFrame, isAnimating: { MotionInFlight.isAnimating }) { late, turn in
            Signposter.motion.lateCommit(lateMilliseconds: late, turnMilliseconds: turn)
        }
        start()
    }

    /// A counter that does not watch the run loop until ``start()`` (tests drive ``turnDidWake()`` and
    /// ``commitDidEnd()``).
    ///
    /// - Parameters:
    ///   - newestFrame: The vsync grid (tests pass a fixed sample).
    ///   - isAnimating: Whether a Motion animation runs.
    ///   - now: The clock (`CACurrentMediaTime`, the base of frame ticks); tests pass fixed times.
    ///   - record: Gets each late commit: how long after the vsync it ended, and its turn, in ms.
    init(newestFrame: @escaping @MainActor () -> DisplayFrameSample?, isAnimating: @escaping @MainActor () -> Bool,
         now: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
         record: @escaping @MainActor (_ lateMilliseconds: Double, _ turnMilliseconds: Double) -> Void) {
        self.newestFrame = newestFrame
        self.isAnimating = isAnimating
        self.now = now
        self.record = record
    }

    /// Whether the observer is on the main run loop.
    public var isWatching: Bool { observer != nil }

    /// Adds the observer to the main run loop (no effect while it is there).
    func start() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        let made = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Self.order) { [weak self] _, activity in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated {
                if activity == .afterWaiting { self?.turnDidWake() } else { self?.commitDidEnd() }
            }
        }
        guard let made else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
        observer = made
    }

    /// Removes the observer.
    func stop() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        turnStart = nil
    }

    /// The main run loop woke: a turn starts (timed only while an animation runs).
    func turnDidWake() {
        turnStart = isAnimating() ? now() : nil
    }

    /// A Core Animation commit ended (or a pass with nothing to commit): while an animation runs, judge it against
    /// the vsync of the frame its turn began in.
    func commitDidEnd() {
        guard isAnimating() else {
            turnStart = nil
            return
        }
        let end = now()
        let start = turnStart
        // A turn that does not sleep starts where this one's commit ended.
        turnStart = end
        guard let start, let frame = newestFrame(), frame.phase(at: start) != .unknown else {
            unjudgedCount &+= 1
            return
        }
        judgedCount &+= 1
        let deadline = frame.vsync(after: start)
        guard end > deadline else { return }
        lateCount &+= 1
        record((end - deadline) * 1_000, (end - start) * 1_000)
    }
}
