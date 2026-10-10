import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// The connecting window starts as bare glass: the mark resolves in after
/// the mark delay and the status line after the text delay, so a fast
/// launch never shows either; a failure shows both at once.
@MainActor @Suite struct LaunchMarkStaggerTests {
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        let clock = ManualClock()
        let view: DaemonConnectingView

        init() {
            window.isReleasedWhenClosed = false
            view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), clock: clock)
        }

        /// Advances the clock to `seconds` after the view entered the window.
        /// The fired deadline wakes on the global pool and hops to the main
        /// actor; the caller waits for its effect (a fixed number of yields
        /// lost that race on a host running 32 suite processes).
        func advance(to seconds: Double, from elapsed: inout Double) async {
            await clock.sleepers(atLeast: 1)
            clock.advance(by: .seconds(seconds - elapsed))
            elapsed = seconds
        }
    }

    @Test func markThenStatusAfterTheirDelays() async throws {
        let h = Harness()
        h.view.apply(.connecting)
        h.window.contentView!.addSubview(h.view)
        #expect(!h.view.mark.isRevealed && !h.view.isTitleShown)
        // Both timers registered, so each deadline counts from the same instant.
        await h.clock.sleepers(atLeast: 2)
        var elapsed = 0.0
        await h.advance(to: MotionTunables.launchMarkDelay.value, from: &elapsed)
        try await waitForCondition("the mark reveals", timeout: .seconds(10), sourceLocation: #_sourceLocation) { h.view.mark.isRevealed }
        #expect(!h.view.isTitleShown)
        await h.advance(to: MotionTunables.launchTextDelay.value, from: &elapsed)
        try await waitForCondition("the status line shows", timeout: .seconds(10), sourceLocation: #_sourceLocation) { h.view.isTitleShown }
    }

    @Test func contentArrivingFirstShowsNeither() async {
        let h = Harness()
        h.window.contentView!.addSubview(h.view)
        await h.clock.sleepers(atLeast: 2)
        h.view.removeFromSuperview()
        h.clock.advance(by: .seconds(5))
        for _ in 0..<20 { await Task.yield() }
        #expect(!h.view.mark.isRevealed)
        #expect(!h.view.isTitleShown)
    }

    @Test func failureShowsMarkAndStatusAtOnce() {
        let h = Harness()
        h.window.contentView!.addSubview(h.view)
        h.view.apply(.unavailable(.launchFailed("exit 1")))
        #expect(h.view.mark.isRevealed)
        #expect(h.view.isTitleShown)
        #expect(h.view.titleText == Strings.daemonUnavailable)
    }
}
