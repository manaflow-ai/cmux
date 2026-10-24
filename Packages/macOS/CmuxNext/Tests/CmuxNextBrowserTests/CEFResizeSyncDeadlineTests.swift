import AppKit
@testable import CmuxNextBrowser
import Testing

/// Review 2 of PL-cef-layer slice 1: a hosted page's resize wait (fork API 27) held the window's
/// commit for the whole 8 ms tunable on every motion frame, a full 120 Hz frame on top of cmux's own
/// layout, and the value was read once when hosting began, so a tunable edit or a display with
/// another refresh rate never reached the fork. The wait is capped at half the shortest frame of all
/// displays and re-applied at the next show or display change, with a fork call only when it changed
/// and taken.
@MainActor
@Suite struct CEFResizeSyncDeadlineTests {
    /// The tunable in ms, the frame interval of each screen (empty: no screen) and the deadline the fork gets.
    nonisolated struct Case: Sendable {
        let tunable: Int32
        let refreshIntervals: [Double]
        let expected: Int32
    }

    @Test(arguments: [
        Case(tunable: 8, refreshIntervals: [1.0 / 60], expected: 8),
        Case(tunable: 8, refreshIntervals: [1.0 / 120], expected: 4),
        Case(tunable: 100, refreshIntervals: [1.0 / 60], expected: 8),
        Case(tunable: 2, refreshIntervals: [1.0 / 120], expected: 2),
        Case(tunable: 0, refreshIntervals: [1.0 / 60], expected: 0),
        Case(tunable: 8, refreshIntervals: [], expected: 8),
        Case(tunable: -3, refreshIntervals: [], expected: 0),
        // Review 2: the commit the wait holds is the process's one main-thread commit, for every window: a 60 Hz
        // and a 120 Hz display cap it at half the 120 Hz frame, wherever the resizing window is.
        Case(tunable: 8, refreshIntervals: [1.0 / 60, 1.0 / 120], expected: 4),
        Case(tunable: 8, refreshIntervals: [0, 1.0 / 60], expected: 8),
    ])
    func theWaitNeverPassesHalfTheShortestDisplayFrame(_ value: Case) {
        #expect(CEFResizeSyncDeadline(tunableMilliseconds: value.tunable, refreshIntervals: value.refreshIntervals).milliseconds
            == value.expected)
    }

    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: Bool = true, deadline: @escaping () -> Int32,
                     refreshInterval: @escaping () -> Double?) -> CEFLayerHosting {
        makeHosting(enabled: enabled, deadline: deadline, refreshIntervals: { refreshInterval().map { [$0] } ?? [] })
    }

    func makeHosting(enabled: Bool = true, deadline: @escaping () -> Int32,
                     refreshIntervals: @escaping () -> [Double]) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: deadline, refreshIntervals: refreshIntervals)
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

    @Test func aDisplayChangeReappliesTheDeadline() {
        var intervals = [1.0 / 60]
        let hosting = makeHosting(deadline: { 8 }, refreshIntervals: { intervals })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        // A 120 Hz display joins: the process's commit now has a 120 Hz frame to keep.
        intervals = [1.0 / 60, 1.0 / 120]
        hosting.displaysChanged()
        #expect(fake.syncs.map { $0.timeoutMs } == [8, 4])
        hosting.displaysChanged()
        #expect(fake.syncs.count == 2)
    }

    /// Review 2: leaving the window (no screen) sent the uncapped tunable and coming back the capped value: two
    /// fork calls per hosted page per detach and attach.
    @Test func aDetachAndReattachMakeNoForkCall() {
        let hosting = makeHosting(deadline: { 8 }, refreshInterval: { 1.0 / 120 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        #expect(view.window == nil)
        hosting.windowDidChange()
        hosting.windowDidChange()
        #expect(fake.syncs.map { $0.timeoutMs } == [4])
    }

    /// Review 2: a deadline the fork refused (a closed browser's id) was recorded as applied, so no later call
    /// retried it.
    @Test func aRefusedDeadlineIsRetriedAtTheNextShow() {
        fake.syncAccepts = false
        let hosting = makeHosting(deadline: { 8 }, refreshInterval: { 1.0 / 60 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        #expect(fake.syncs.map { $0.timeoutMs } == [8])
        fake.syncAccepts = true
        hosting.pageShown(browser: 4)
        hosting.pageShown(browser: 4)
        #expect(fake.syncs.map { $0.browser } == [3, 4])
    }

    /// Review 2: the browser that names the page window was the last one shown, and could be a closed one (a popup
    /// host's placeholder, the pane's last Chromium tab before a non-Chromium tab shows).
    @Test func aClosedBrowserHandsThePageWindowToALiveOne() {
        var deadline: Int32 = 8
        let hosting = makeHosting(deadline: { deadline }, refreshInterval: { 1.0 / 60 })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        hosting.windowBrowsersChanged([5, 6])
        deadline = 2
        hosting.displaysChanged()
        #expect(fake.syncs.map { $0.browser } == [3, 5])
        #expect(fake.syncs.map { $0.timeoutMs } == [8, 2])
        // A live browser stays.
        hosting.windowBrowsersChanged([6, 5])
        deadline = 1
        hosting.displaysChanged()
        #expect(fake.syncs.last?.browser == 5)
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
