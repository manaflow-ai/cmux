import AppKit
@testable import CmuxNextBrowser
import Testing

/// Review 2 of PL-cef-layer slice 1: a hosted page's resize wait (fork API 27) held the window's
/// commit for the whole 8 ms tunable on every motion frame, a full 120 Hz frame on top of cmux's own
/// layout, and the value was read once when hosting began, so a tunable edit or a display with
/// another refresh rate never reached the fork. The wait is now capped at half a display frame and
/// re-applied at the next show or screen change, with a fork call only when it changed.
@MainActor
@Suite struct CEFResizeSyncDeadlineTests {
    /// The tunable in ms, the display's frame interval (nil: no screen yet) and the deadline the fork gets.
    nonisolated struct Case: Sendable {
        let tunable: Int32
        let refreshInterval: Double?
        let expected: Int32
    }

    @Test(arguments: [
        Case(tunable: 8, refreshInterval: 1.0 / 60, expected: 8),
        Case(tunable: 8, refreshInterval: 1.0 / 120, expected: 4),
        Case(tunable: 100, refreshInterval: 1.0 / 60, expected: 8),
        Case(tunable: 2, refreshInterval: 1.0 / 120, expected: 2),
        Case(tunable: 0, refreshInterval: 1.0 / 60, expected: 0),
        Case(tunable: 8, refreshInterval: nil, expected: 8),
        Case(tunable: -3, refreshInterval: nil, expected: 0),
    ])
    func theWaitNeverPassesHalfADisplayFrame(_ value: Case) {
        #expect(CEFResizeSyncDeadline(tunableMilliseconds: value.tunable, refreshInterval: value.refreshInterval).milliseconds
            == value.expected)
    }

    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: Bool = true, deadline: @escaping () -> Int32,
                     refreshInterval: @escaping () -> Double?) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: deadline, refreshInterval: { _ in refreshInterval() })
        hosting.view = view
        return hosting
    }

    @Test func aHostedPageOnA120HzDisplayWaitsHalfAFrameAtMost() {
        let hosting = makeHosting(deadline: { 8 }, refreshInterval: { 1.0 / 120 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        #expect(fake.syncs.map { $0.browser } == [3])
        #expect(fake.syncs.map { $0.timeoutMs } == [4])
    }

    @Test func aTunableChangeReachesAHostedPageAtItsNextShowWithOneCall() {
        var deadline: Int32 = 8
        let hosting = makeHosting(deadline: { deadline }, refreshInterval: { 1.0 / 60 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        // Tab switches in a hosted pane: the deadline did not change, nothing reaches the fork.
        for browser: Int32 in [4, 3] { hosting.pageShown(browser: browser) }
        #expect(fake.syncs.map { $0.timeoutMs } == [8])
        deadline = 3
        hosting.pageShown(browser: 4)
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.map { $0.timeoutMs } == [8, 3])
        #expect(fake.syncs.last?.browser == 4)
        #expect(fake.calls.count == 1)
    }

    @Test func aDisplayWithAnotherRefreshRateReappliesTheDeadline() {
        var interval = 1.0 / 60
        let hosting = makeHosting(deadline: { 8 }, refreshInterval: { interval })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        interval = 1.0 / 120
        hosting.windowDidChange()
        #expect(fake.syncs.map { $0.timeoutMs } == [8, 4])
        hosting.windowDidChange()
        #expect(fake.syncs.count == 2)
    }

    @Test func aPageInItsOwnWindowGetsNoDeadlineFromAShowOrAScreenChange() {
        let hosting = makeHosting(enabled: false, deadline: { 8 }, refreshInterval: { 1.0 / 120 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        hosting.pageShown(browser: 3)
        hosting.windowDidChange()
        #expect(fake.syncs.isEmpty)
        #expect(fake.calls.isEmpty)
    }
}
