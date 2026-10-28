import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// `debug.motion` work `ca.commit` (MotionCommitProbe): the span of each Core Animation commit,
/// which holds Chromium's pre-commit wait for a page's frame at a new size (fork API 27). Review 2 of
/// PL-cef-layer slice 1: no bench measured that wait, so a resize sync that cost a frame per motion
/// frame could not be told from one that cost nothing.
@MainActor
@Suite(.serialized) struct MotionCommitProbeTests {
    final class FakeClock {
        var time: CFTimeInterval = 100
    }

    @MainActor final class AlphaLog {
        var atCommit: [CGFloat] = []
    }

    @Test func eachCommitIsRecordedInMilliseconds() {
        let clock = FakeClock()
        var recorded: [Double] = []
        let probe = MotionCommitProbe(now: { clock.time }) { recorded.append($0) }
        probe.commitWillStart()
        clock.time += 0.006
        probe.commitDidEnd()
        #expect(recorded.count == 1)
        #expect(abs((recorded.first ?? 0) - 6) < 0.001)
    }

    @Test func anEmptyPassAndAnEndWithoutAStartRecordNothing() {
        let clock = FakeClock()
        var recorded: [Double] = []
        let probe = MotionCommitProbe(now: { clock.time }) { recorded.append($0) }
        probe.commitDidEnd()
        probe.commitWillStart()
        clock.time += 0.00001
        probe.commitDidEnd()
        // The end consumed its start: a second end has nothing to pair with.
        clock.time += 0.01
        probe.commitDidEnd()
        #expect(recorded.isEmpty)
    }

    @Test func recordingAddsCommitsToTheMotionWorkReport() {
        MotionTrace.start()
        defer { MotionTrace.stop() }
        MotionTrace.record(MotionCommitProbe.workName, milliseconds: 7)
        #expect(MotionTrace.work[MotionCommitProbe.workName] == [7])
        MotionTrace.stop()
        MotionTrace.record(MotionCommitProbe.workName, milliseconds: 9)
        #expect(MotionTrace.work[MotionCommitProbe.workName] == [7])
    }

    /// Review 2: the probe was a static of `MotionTrace` (global run-loop observers on a package type). The
    /// `debug.motion` handler owns it now: `start` adds its observers, `stop` removes them, and a recording without
    /// one adds none.
    @Test func theDebugMotionHandlerStartsAndStopsItsOwnProbe() {
        let probe = MotionCommitProbe(record: { _ in })
        _ = MotionDebug.handle(["action": "start"], windows: [], commitProbe: probe)
        #expect(probe.isRunning)
        _ = MotionDebug.handle(["action": "read"], windows: [], commitProbe: probe)
        #expect(probe.isRunning)
        _ = MotionDebug.handle(["action": "stop"], windows: [], commitProbe: probe)
        #expect(!probe.isRunning)
        #expect(!MotionTrace.isEnabled)
    }

    /// A popup's open forced a commit (`CATransaction.flush` in `openPopup`) so the
    /// card's first frame (opacity 0) reached the screen before the window turned opaque. The window
    /// now turns opaque right after the run loop's own commit of the open's turn: at Core Animation's
    /// commit order (one after the probe's `beforeOrder`) it is still clear, and before the run loop
    /// waits it is opaque, so the card shows in the frame of the key that opened it, with no flash and
    /// no extra commit.
    @Test(.enabled("needs a screen and animation speed on, or every popup snaps") { await PopupGrowMotionTests.queuesAnimations() })
    func aPopupTurnsOpaqueRightAfterTheCommitOfItsOpensTurn() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        content.wantsLayer = true
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.resetPopupScale(); window.orderOut(nil) }
        try #require(window.screen != nil)

        let log = AlphaLog()
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let commit = CFRunLoopObserverCreateWithHandler(nil, activities, false, MotionCommitProbe.beforeOrder + 1) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { log.atCommit.append(window.alphaValue) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        defer { CFRunLoopObserverInvalidate(commit) }

        window.openPopup(pivot: CGPoint(x: 150, y: 200))
        #expect(window.alphaValue == 0, "the window turned opaque before the card's first frame was committed")
        PopupGrowMotionTests.commitTurn()

        #expect(log.atCommit.first == 0, "the commit of the open's turn ran with the window already opaque")
        #expect(window.alphaValue == 1, "the popup did not show in the frame of its open's turn")
    }
}
