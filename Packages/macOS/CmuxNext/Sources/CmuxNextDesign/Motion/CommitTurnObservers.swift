#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat

/// The seam between the main run loop's turn end and ``LiveResizeFrameProbe`` (FRAME OWNER REFACTOR S7, DEBUG and bench
/// builds): after ``arm()``, `beforeCommit` runs once just before Core Animation's commit observer (order 2,000,000),
/// after AppKit's layout and display passes, and `afterCommit` runs once just after it, as ``MotionCommitProbe``'s.
@MainActor
final class CommitTurnObservers {
    /// One before Core Animation's commit observer: the turn's contents as its commit sends them.
    static let beforeCommitOrder: CFIndex = 1_999_999
    /// One after it: the turn's commit just ended.
    static let afterCommitOrder: CFIndex = 2_000_001

    private let beforeCommit: @MainActor () -> Void
    private let afterCommit: @MainActor () -> Void
    private var before: CFRunLoopObserver?
    private var after: CFRunLoopObserver?

    init(beforeCommit: @escaping @MainActor () -> Void, afterCommit: @escaping @MainActor () -> Void) {
        self.beforeCommit = beforeCommit
        self.afterCommit = afterCommit
    }

    /// The turn running now calls each callback once at its end (no effect for one already armed in it).
    func arm() {
        if before == nil {
            let made = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          false, Self.beforeCommitOrder) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fireBefore() } // main-proof: added to the main run loop only
            }
            if let made {
                before = made
                CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
            }
        }
        guard after == nil else { return }
        // One shot: the run loop drops it after it runs.
        let made = MainRunLoopObserver.afterCommitObserver(activities: [.beforeWaiting, .exit], repeats: false,
                                                           order: Self.afterCommitOrder) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireAfter() } // main-proof: added to the main run loop only
        }
        after = made
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
    }

    private func fireBefore() {
        before = nil
        beforeCommit()
    }

    private func fireAfter() {
        after = nil
        afterCommit()
    }
}
#endif
