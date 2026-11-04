import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// A window out of the person's sight gets no animation frames (Chrome's rule for a hidden tab).
/// The feat tip Swift suite (41190088925, 2026-10-31) was cut short at 1500 s with its main thread in
/// display-link frames that laid out sidebar rows: an animation in a window that was ordered out or
/// covered stepped and laid out every frame (or every 100 ms stall tick), though nobody saw it.
/// Now an animation that starts in such a window, or runs when it goes out of sight, ends at once at
/// its final state (its completion runs), the window's display link goes, and its rows lay out once.
/// A window in sight animates as before.
///
/// The swift test process runs no AppKit event loop, so WindowServer's occlusion reports never reach
/// it (a window it orders in never reads `.visible`). Each test sets its window's occlusion state and
/// posts the report AppKit would post (`didChangeOcclusionStateNotification`), visible and covered.
@MainActor
@Suite(.serialized, .closesItsWindows, .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
struct OutOfSightFramesTests {
    static let moving = MotionPolicy(speed: .fast, reduceMotion: false)

    final class CountingView: NSView {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// A ten-second animation on the window's clock that asks for a layout on every step.
    final class Glide: MotionAnimating {
        let seconds: Double
        private(set) var elapsed = 0.0
        private(set) var ended = false
        weak var view: NSView?

        init(seconds: Double = 10, view: NSView) {
            self.seconds = seconds
            self.view = view
        }

        func motionStep(_ dt: Double) -> Bool {
            elapsed = min(seconds, elapsed + dt)
            view?.needsLayout = true
            ended = elapsed >= seconds
            return !ended
        }
    }

    static let frame = NSRect(x: 160, y: 160, width: 240, height: 600)

    /// A window whose occlusion state the test sets: what WindowServer would report for it.
    final class ReportedWindow: NSWindow {
        var reported: NSWindow.OcclusionState = [.visible]
        override var occlusionState: NSWindow.OcclusionState { reported }
    }

    /// A window ordered in and reported visible, with a counting content view. The caller closes it.
    static func orderedInWindow() -> (ReportedWindow, CountingView) {
        let view = CountingView(frame: NSRect(origin: .zero, size: frame.size))
        let window = ReportedWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        _ = FrameScheduler.forWindow(window)
        window.orderFrontRegardless()
        return (window, view)
    }

    /// The occlusion report WindowServer sends AppKit when `window` is ordered in, covered or uncovered.
    static func report(_ state: NSWindow.OcclusionState, for window: ReportedWindow) {
        window.reported = state
        // AppKit posts this report on the default center, which is where FrameScheduler's one occlusion observer
        // listens; its object is a window only this test made and holds, so every observer that acts on it acts on
        // that window alone (no other suite has it), as on WindowServer's own report.
        // global-notice-allow: the object is this test's own window (see above)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @Test func anAnimationInAnOrderedOutWindowEndsAtOnceWithNoDisplayLink() async throws {
        let (window, view) = Self.orderedInWindow()
        defer { window.close() }
        Self.report([.visible], for: window)
        window.orderOut(nil)
        Self.report([], for: window)
        let scheduler = FrameScheduler.forWindow(window)

        let slot = SidebarCardSlotMotion(policy: { Self.moving })
        _ = slot.height(toward: 0, in: view)
        #expect(slot.height(toward: 120, in: view) == 120, "the ordered-out window's list started a spring")
        #expect(!slot.isMoving)
        #expect(!Motion.canAnimate(in: view), "a change in an ordered-out window was allowed to animate")

        let glide = Glide(view: view)
        MotionClock.forWindow(window).run(glide, trace: "test.glide")
        #expect(glide.ended, "an animation that started out of sight did not end at once")
        #expect(!scheduler.hasLink, "an ordered-out window holds a display link")

        view.layoutSubtreeIfNeeded()
        let layouts = view.layouts
        for frame in 0..<10 {
            scheduler.frameDidFire(timestamp: Double(frame) / 120)
            view.layoutSubtreeIfNeeded()
        }
        #expect(view.layouts == layouts, "the out-of-sight rows laid out on frames")
    }

    @Test func anAnimationRunningWhenItsWindowIsCoveredEndsAtOnce() async throws {
        let (window, view) = Self.orderedInWindow()
        defer { window.close() }
        let scheduler = FrameScheduler.forWindow(window)
        let glide = Glide(view: view)
        MotionClock.forWindow(window).run(glide, trace: "test.glide")
        try #require(!glide.ended && scheduler.hasLink, "a window in sight did not animate")

        // Another window covers it: WindowServer reports it no longer visible while it stays ordered in.
        Self.report([], for: window)
        #expect(window.isVisible)
        try await Task.sleep(for: .milliseconds(250))
        #expect(glide.ended, "the covered window's animation kept stepping")
        #expect(!scheduler.hasLink, "a covered window holds a display link")

        view.layoutSubtreeIfNeeded()
        let layouts = view.layouts
        try await Task.sleep(for: .milliseconds(600))
        view.layoutSubtreeIfNeeded()
        #expect(view.layouts - layouts <= 1, "the covered rows laid out \(view.layouts - layouts) times in 600 ms")
    }

    @Test func aWindowInSightStillAnimates() async throws {
        let (window, view) = Self.orderedInWindow()
        defer { window.close() }
        // WindowServer reports it visible (ordered in, nothing over it): it is in sight.
        Self.report([.visible], for: window)
        #expect(Motion.canAnimate(in: view))
        let glide = Glide(view: view)
        MotionClock.forWindow(window).run(glide, trace: "test.glide")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!glide.ended && glide.elapsed > 0, "a window in sight did not step its animation")
        #expect(FrameScheduler.forWindow(window).hasLink)

        // Covered, then uncovered: in sight again, a new animation steps.
        MotionClock.forWindow(window).stop(glide)
        Self.report([], for: window)
        Self.report([.visible], for: window)
        let uncovered = Glide(view: view)
        MotionClock.forWindow(window).run(uncovered, trace: "test.glide")
        #expect(!uncovered.ended && Motion.canAnimate(in: view), "a window reported visible again was kept out of sight")
        MotionClock.forWindow(window).stop(uncovered)

        // Ordered out and back in: in sight again, it animates again.
        window.orderOut(nil)
        window.orderFrontRegardless()
        let again = Glide(view: view)
        MotionClock.forWindow(window).run(again, trace: "test.glide")
        #expect(!again.ended, "a window ordered back in did not animate")
        MotionClock.forWindow(window).stop(again)
    }
}
