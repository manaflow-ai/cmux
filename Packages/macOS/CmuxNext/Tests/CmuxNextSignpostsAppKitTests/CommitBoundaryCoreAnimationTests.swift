import CmuxNextSignposts
import CoreFoundation
import QuartzCore
import Testing

/// `CommitBoundary` is only correct while Core Animation commits at an order below `CommitBoundary.order`.
/// This reads the main run loop's observers in a bare test process (Core Animation only, no `NSApplication`) on
/// the macOS that runs it (14, 15, 26 and 27 are supported), so a change in a new major fails here. AppKit's own
/// display observers are checked by `CommitBoundaryAppKitTests` (CmuxNextAppTests) and in the running app by
/// `debug.commit_boundary`. The run-loop tests that need no Core Animation are in `SignpostsTests`
/// (CmuxNextSignpostsTests, in the Linux tier).
@Suite(.serialized)
@MainActor
struct CommitBoundaryCoreAnimationTests {
    /// Runs one main run-loop turn that polls and exits without waiting (as `SignpostsTests` does). A mode with no
    /// source returns before notifying observers, so a far-future timer keeps the default mode non-empty for the turn.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test("Core Animation's commit observer on this macOS runs before the boundary")
    func coreAnimationCommitsBeforeTheBoundary() throws {
        // A property change on the main thread opens an implicit transaction, which installs
        // Core Animation's commit observer on the main run loop.
        let layer = CALayer()
        layer.opacity = 0.5
        let audit = CommitBoundaryAudit.mainRunLoop()
        pollingTurn()
        try #require(!audit.coreAnimation.isEmpty, "no Core Animation commit observer on the main run loop: \(audit.observers)")
        #expect(audit.late.isEmpty, "observers after the boundary: \(audit.late)")
    }
}
