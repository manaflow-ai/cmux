import CoreFoundation
import QuartzCore

/// Times each Core Animation commit of the main run loop while `debug.motion` records
/// (``MotionTrace`` work `ca.commit`).
///
/// Core Animation commits the main thread's transaction from a run-loop observer at order
/// 2,000,000 (before waiting and on exit; `CommitBoundaryAudit` in CmuxNextSignposts reads the
/// orders on each macOS). This probe stamps the time one order before it, after AppKit's layout
/// and display passes, and one order after it, so the span is the commit alone: layer layout and
/// display, the encode, and every pre-commit handler. Chromium's resize wait is such a handler
/// (`CATransactionCoordinator`, fork API 27 `cmux_browser_set_resize_sync`): with Chromium pages
/// the span is how long a page's resize held the frame, the number a light and STRESS motion
/// bench compares with layer hosting off and on.
///
/// Commits under ``floorMilliseconds`` are run-loop passes with nothing to commit and are not
/// recorded, so an idle stretch does not fill the trace. The observers exist only while
/// recording (DEBUG builds' `debug.motion start` to `stop`).
///
/// Not measured: commits outside the run-loop observer, which Chromium's pre- and post-commit
/// waits also hold: an explicit `CATransaction.flush()` (`Motion+Popup`) and the flushes AppKit
/// makes inside a window's live resize. A bench of the window's live resize reads its frames, not
/// `ca.commit`.
///
/// The `debug.motion` handler owns the probe (`AppControl` makes one and passes it to
/// ``MotionDebug/handle(_:windows:samplers:commitProbe:)``); no type holds one statically.
public final class MotionCommitProbe {
    /// The `MotionTrace.work` name of the commits.
    static let workName = "ca.commit"
    /// One before Core Animation's commit observer (order 2,000,000).
    static let beforeOrder: CFIndex = 1_999_999
    /// One after it (CmuxNextSignposts' `CommitBoundary.order`).
    static let afterOrder: CFIndex = 2_000_001
    /// A pass shorter than this committed nothing worth counting.
    static let floorMilliseconds = 0.05

    private var observers: [CFRunLoopObserver] = []
    private var commitStart: CFTimeInterval?
    private let record: (Double) -> Void
    private let now: () -> CFTimeInterval

    /// A probe that adds each commit to ``MotionTrace`` work ``workName`` while it records.
    public convenience init() {
        self.init { MotionTrace.record(MotionCommitProbe.workName, milliseconds: $0) }
    }

    /// - Parameters:
    ///   - now: the clock (`CACurrentMediaTime`); tests pass fixed times.
    ///   - record: gets the duration of each commit in ms (`MotionTrace` adds it to its work).
    init(now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }, record: @escaping (Double) -> Void) {
        self.now = now
        self.record = record
    }

    /// Whether the observers are on the main run loop.
    public var isRunning: Bool { !observers.isEmpty }

    /// Adds the two observers to the main run loop (no effect while they exist).
    public func start() {
        guard observers.isEmpty else { return }
        commitStart = nil
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        // Run-loop observers: the commit has no async-native signal. Both run on the main thread
        // (they are added to CFRunLoopGetMain() only, below).
        let before = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Self.beforeOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.commitWillStart() } // main-proof: main run loop observer
        }
        let after = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Self.afterOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.commitDidEnd() } // main-proof: main run loop observer
        }
        for observer in [before, after].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    /// Removes the observers.
    public func stop() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        commitStart = nil
    }

    func commitWillStart() {
        commitStart = now()
    }

    func commitDidEnd() {
        guard let start = commitStart else { return }
        commitStart = nil
        let milliseconds = (now() - start) * 1_000
        if milliseconds >= Self.floorMilliseconds { record(milliseconds) }
    }
}
