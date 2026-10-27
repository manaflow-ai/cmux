import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The knob's rest after the last scroll step is a flexible, never-early deadline: its sleep asks the
/// OS for ``WakeLeeway``'s tolerance so the wake can share a timer fire with others (Chromium's
/// `kFlexibleNoSooner` with `kDefaultLeeway`, base/task/delay_policy.h; p14-energy Q1).
@MainActor
@Suite(.serialized)
struct ThinScrollerRestLeewayTests {
    @Test func theRestDeadlineAsksForTheWakeLeewayTolerance() async throws {
        let clock = ManualClock()
        let center = NotificationCenter()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ThinScroller(frame: .zero, clock: clock, notificationCenter: center)
        SystemScrollers.followThin(scrollView)
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        scrollView.tile()
        let scroller = try #require(scrollView.verticalScroller as? ThinScroller)
        scroller.isEnabled = true
        scroller.knobProportion = 0.25

        center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        try await clock.waitForSleeper()

        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: ThinScroller.restDelay))
        #expect(request.tolerance == WakeLeeway.window(delay: ThinScroller.restDelay).tolerance)
        #expect(request.tolerance == WakeLeeway.defaultAlignment)

        clock.advance(by: ThinScroller.restDelay)
        await scroller.restTask?.value
        #expect(!scroller.isKnobShown)
    }
}
