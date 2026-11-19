import CoreFoundation
import QuartzCore

/// A measure branch's probe (no PR): splits each turn of the main run loop while `debug.motion` records, by run-loop
/// observers alone (no timer, nothing inside a hot call).
///
/// A turn runs from the run loop's wake to its next wait. Its parts, each named by the stage whose observer ends it:
/// - `wake`: from the wake to the first pass: what woke the run loop (a timer, the main queue, a port's source such
///   as the display link) and the blocks after it;
/// - `passes`: from each pass's start to the next pass or to the wait's observers: blocks, sources, and each timer,
///   queue drain and port source that a pass serves with no wait (an observer cannot tell them apart);
/// - `events`: from a run loop's exit to its next entry: AppKit's work between two runs (an event's dispatch);
/// - `before_commit`: the wait's (or the exit's) observers below Core Animation's commit: AppKit's layout and display
///   pass and the app's own observers there, with the `NSView.layout()` calls in them;
/// - `commit`: Core Animation's commit (order 2,000,000; an observer of the app at 1,999,999 is in this part or in
///   the one before, by which of the two came first to the run loop);
/// - `after_commit`: the observers after it, to this probe's last one. An observer added later at the last order
///   runs after it and is in no part: the layout's work after a commit has its own spans (`layout.release`).
///
/// A turn at or above ``noteMilliseconds`` leaves one `MotionTrace` note with its parts, written at its end. Each turn,
/// long or not, leaves its end, its length and its commit part in ``each`` (4 numbers, no text).
/// ``callbacks`` counts the probe's own observer calls: its cost in the frames that it measures.
public final class MotionTurnProbe {
    /// A turn at or above this leaves a note.
    static let noteMilliseconds = 4.0
    /// The probe's own observer calls, the turns that ended, and those with a note, since the last ``start()``.
    public private(set) var callbacks = 0
    public private(set) var turns = 0
    public private(set) var noted = 0
    /// Each turn that ended since the last ``start()``, in order, long or not: its end (`CACurrentMediaTime`), its
    /// length, its part before the commit and its commit part, in ms. A reader finds the commits near a late frame
    /// with it, or that there was none. At most ``keptTurns``: ``turns`` above this count says that the keep was full.
    /// The space is reserved at ``start()``, so a turn's end adds one value and allocates nothing.
    public private(set) var each: [Turn] = []
    static let keptTurns = 8192

    /// One turn of ``each``.
    public struct Turn {
        public var end: CFTimeInterval
        public var total: Double
        public var beforeCommit: Double
        public var commit: Double
    }

    private static let labels = ["wake", "passes", "events", "before_commit", "commit", "after_commit"]
    private static let wake = 0
    private static let passes = 1
    private static let events = 2
    private static let beforeCommit = 3
    private static let commit = 4
    private static let afterCommit = 5

    private var observers: [CFRunLoopObserver] = []
    private var isOpen = false
    private var part = 0
    private var began: CFTimeInterval = 0
    private var mark: CFTimeInterval = 0
    private var seconds = [Double](repeating: 0, count: 6)
    private var passCount = 0
    /// `NSView.layout()` calls and window layout passes at the turn's start, and the calls at the last pass's start.
    private var viewMark = 0
    private var windowMark = 0
    private var passMark = 0
    private var passLayouts = 0

    public init() {}

    /// Adds the observers to the main run loop (no effect while they exist).
    public func start() {
        guard observers.isEmpty else { return }
        callbacks = 0
        turns = 0
        noted = 0
        each.removeAll(keepingCapacity: true)
        each.reserveCapacity(Self.keptTurns)
        isOpen = false
        let wait = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        // Run-loop observers: a turn's stages have no async-native signal. Each runs on the main thread (they are
        // added to CFRunLoopGetMain() only, below).
        let wake = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.woke() } // main-proof: main run loop observer
        }
        let entry = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.entry.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.stamp(next: MotionTurnProbe.passes) } // main-proof: main run loop observer
        }
        let pass = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeTimers.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.passBegan() } // main-proof: main run loop observer
        }
        let waits = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, wait, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.waitBegan() } // main-proof: main run loop observer
        }
        let before = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, wait, true, MotionCommitProbe.beforeOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.commitWillStart() } // main-proof: main run loop observer
        }
        let after = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, wait, true, MotionCommitProbe.afterOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.stamp(next: MotionTurnProbe.afterCommit) } // main-proof: main run loop observer
        }
        let exits = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.stamp(next: MotionTurnProbe.events) } // main-proof: main run loop observer
        }
        let ends = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnEnded() } // main-proof: main run loop observer
        }
        for observer in [wake, entry, pass, waits, before, after, exits, ends].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    /// Removes the observers.
    public func stop() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        isOpen = false
    }

    /// The run loop woke: a turn starts.
    func woke() {
        callbacks += 1
        let now = CACurrentMediaTime()
        isOpen = true
        part = Self.wake
        began = now
        mark = now
        for index in seconds.indices { seconds[index] = 0 }
        passCount = 0
        passLayouts = 0
        viewMark = LayoutPassGuard.shared.viewLayoutCalls
        windowMark = LayoutPassGuard.shared.windowLayoutPasses
    }

    /// The time since the last stamp is the open part's; `next` is open from now.
    func stamp(next: Int) {
        callbacks += 1
        guard isOpen else { return }
        let now = CACurrentMediaTime()
        seconds[part] += now - mark
        mark = now
        part = next
    }

    func passBegan() {
        stamp(next: Self.passes)
        passCount += 1
    }

    func waitBegan() {
        stamp(next: Self.beforeCommit)
        passMark = LayoutPassGuard.shared.viewLayoutCalls
    }

    func commitWillStart() {
        stamp(next: Self.commit)
        passLayouts += LayoutPassGuard.shared.viewLayoutCalls &- passMark
    }

    /// The run loop is about to wait: the turn ends, and a long one leaves its note.
    func turnEnded() {
        stamp(next: Self.afterCommit)
        guard isOpen else { return }
        isOpen = false
        turns += 1
        let total = (mark - began) * 1_000
        if each.count < Self.keptTurns {
            each.append(Turn(end: mark, total: total, beforeCommit: seconds[Self.beforeCommit] * 1_000, commit: seconds[Self.commit] * 1_000))
        }
        guard total >= Self.noteMilliseconds else { return }
        noted += 1
        let views = LayoutPassGuard.shared.viewLayoutCalls &- viewMark
        let windows = LayoutPassGuard.shared.windowLayoutPasses &- windowMark
        var text = "turn: total=\(Self.rounded(total))"
        for index in seconds.indices { text += " \(Self.labels[index])=\(Self.rounded(seconds[index] * 1_000))" }
        text += " pass_count=\(passCount) view_layouts=\(views) window_layouts=\(windows) before_commit_view_layouts=\(passLayouts)"
        MotionTrace.note(text)
    }

    private static func rounded(_ milliseconds: Double) -> Double { (milliseconds * 100).rounded() / 100 }
}
