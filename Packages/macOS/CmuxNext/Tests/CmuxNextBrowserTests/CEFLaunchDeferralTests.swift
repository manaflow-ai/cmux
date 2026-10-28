@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A tab's origin orders its Chromium start at launch (``CEFLaunchDeferral``), as Chrome's
/// session restore loads the visible tab first and the rest after startup. A `.restoreVisible` page starts
/// after the first frame and before completion, a `.restoreHidden` one after completion, a `.user` or
/// `.automation` one at once. The page engine here is a fake: it waits as `CEFEngine.makeTab` does, then
/// makes a mock tab; time is a ManualClock that never moves, so a completion is never the failsafe's.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFLaunchDeferralTests {
    @Test func aVisibleRestoredPageStartsAfterTheFirstFrameAndBeforeCompletion() async {
        let s = StartupTestScheduler()
        let engine = FakeLaunchEngine(startup: s.startup)
        let pane = s.startup.hold("Startup.visiblePane")
        let made = engine.make(.restoreVisible)
        s.startup.finishRegistration()
        await Self.settle()
        #expect(engine.started.isEmpty, "Chromium started before the first frame")

        s.startup.firstFrameCommitted()
        s.fire()
        _ = await made.value
        #expect(engine.started == [.restoreVisible])
        s.hand.drain()
        #expect(s.startup.completion == nil, "startup completed before the visible page loaded")
        pane.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        #expect(s.startup.completion?.reason == .visiblePaneLoadedIdle)
    }

    @Test func aHiddenRestoredPageWaitsForCompletion() async {
        let s = StartupTestScheduler()
        let engine = FakeLaunchEngine(startup: s.startup)
        let pane = s.startup.hold("Startup.visiblePane")
        let made = engine.make(.restoreHidden)
        s.startup.finishRegistration()
        s.startup.firstFrameCommitted()
        for _ in 0..<3 { s.fire() }
        await Self.settle()
        #expect(engine.started.isEmpty, "a hidden page started Chromium before startup completed")

        pane.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        #expect(s.startup.completion != nil)
        s.fire()
        _ = await made.value
        #expect(engine.started == [.restoreHidden])
    }

    @Test func aUserOrAutomationPageStartsAtOnce() async {
        let s = StartupTestScheduler()
        let engine = FakeLaunchEngine(startup: s.startup)
        _ = await engine.make(.user).value
        _ = await engine.make(.automation).value
        #expect(engine.started == [.user, .automation], "no first frame came, yet input goes first")
        #expect(!s.startup.log.records.contains { $0.name.description.hasPrefix("Chromium.start") }, "an input page took a launch post")
    }

    /// The visible page's ref waits for the page, and the page waits only for the first frame: the focused
    /// Chromium page loads and completion follows with its reason, never the failsafe's.
    @Test func aFocusedChromiumPageCompletesStartupWithItsLoadNotTheFailsafe() async {
        let s = StartupTestScheduler()
        let engine = FakeLaunchEngine(startup: s.startup)
        let pane = s.startup.hold("Startup.visiblePane")
        let loaded = Task { @MainActor in
            let tab = await engine.make(.restoreVisible).value
            if tab.state.hasEndedLoad { pane.release(.visiblePaneLoadedIdle) }
        }
        await Self.settle()
        s.complete()
        s.fire()
        await loaded.value
        s.hand.drain()
        #expect(s.startup.completion?.reason == .visiblePaneLoadedIdle)
        #expect(!s.startup.failsafeArmed)
    }

    @Test func afterCompletionOrWithNoSchedulerEveryOriginStartsAtOnce() async {
        let s = StartupTestScheduler()
        s.complete()
        let engine = FakeLaunchEngine(startup: s.startup), unordered = FakeLaunchEngine(startup: nil)
        for origin in BrowserTabOrigin.allCases {
            _ = await engine.make(origin).value
            _ = await unordered.make(origin).value
        }
        #expect(engine.started == BrowserTabOrigin.allCases)
        #expect(unordered.started == BrowserTabOrigin.allCases)
    }

    /// Quit drops the held launch posts: a waiting start returns, so its tab task ends (its start then fails
    /// as any start after quit does) instead of waiting forever.
    @Test func quitEndsAWaitingStart() async {
        let s = StartupTestScheduler()
        let deferral = CEFLaunchDeferral(startup: s.startup)
        let visible = Task { @MainActor in await deferral.waitForStart(of: .restoreVisible) }
        let hidden = Task { @MainActor in await deferral.waitForStart(of: .restoreHidden) }
        await Self.settle()
        s.startup.beginQuit()
        await visible.value
        await hidden.value
    }

    /// The launch posts are the scheduler's: one per waiting tab, by name and priority, and no other deferral.
    @Test func theWaitIsALaunchPostOfTheScheduler() {
        #expect(CEFLaunchDeferral.post(of: .user) == nil)
        #expect(CEFLaunchDeferral.post(of: .automation) == nil)
        #expect(CEFLaunchDeferral.post(of: .restoreVisible)?.priority == .afterFirstFrame)
        #expect(CEFLaunchDeferral.post(of: .restoreHidden)?.priority == .afterStartup)
    }

    @Test func aRestoredPagesOriginFollowsWhereItShowsUntilCompletion() {
        let s = StartupTestScheduler()
        let order = CEFLaunchDeferral(startup: s.startup)
        #expect(order.restoredOrigin(isShown: true, wasStarted: false) == .restoreVisible)
        #expect(order.restoredOrigin(isShown: false, wasStarted: false) == .restoreHidden)
        #expect(order.restoredOrigin(isShown: false, wasStarted: true) == .automation, "a started hidden page is deferred again")
        s.complete()
        #expect(order.restoredOrigin(isShown: false, wasStarted: false) == .user)
        #expect(CEFLaunchDeferral(startup: nil).restoredOrigin(isShown: false, wasStarted: false) == .user, "feature off")
    }

    /// The hidden page's one deferral: the deferred page, started when its node shows or at completion.
    @Test func aHiddenPageStartsWhenItShowsOrAtCompletion() {
        let s = StartupTestScheduler()
        let order = CEFLaunchDeferral(startup: s.startup)
        let pane = VisibilityNode(root: "pane", own: .visible)
        let shown = VisibilityNode("tab:shown", own: .hidden, parent: pane), hidden = VisibilityNode("tab:hidden", own: .hidden, parent: pane)
        let starts = StartCount()
        order.startHidden(when: shown) { starts.names.append("shown") }
        order.startHidden(when: hidden) { starts.names.append("hidden") }
        s.startup.finishRegistration()
        s.startup.firstFrameCommitted()
        let held = s.startup.hold("Startup.visiblePane")
        s.fire()
        #expect(starts.names.isEmpty, "a hidden page started before it showed or startup completed")

        shown.set(.visible)
        #expect(starts.names == ["shown"])
        held.release(.visiblePaneLoadedIdle)
        s.hand.drain()
        s.fire()
        s.fire()
        // Completion runs each page's start once more, in post order; the App's start of a started page does nothing.
        #expect(starts.names == ["shown", "shown", "hidden"])
    }

    @Test func theOriginlessConfigurationMeansUser() {
        #expect(Self.originless().origin == .user)
        #expect(BrowserTabConfiguration(origin: .restoreHidden).origin == .restoreHidden)
    }

    /// The deprecated init, called once here on purpose (p08-startup-114 removes it with this test).
    @available(*, deprecated)
    private static func originless() -> BrowserTabConfiguration { BrowserTabConfiguration() }

    /// Lets the waiting tasks run up to their first suspension.
    private static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

/// The starts a test's hidden pages asked for, in order.
@MainActor
private final class StartCount {
    var names: [String] = []
}

/// A page engine that orders its start as `CEFEngine.makeTab` does (``CEFLaunchDeferral``), then makes a mock
/// tab whose load ends at once.
@MainActor
private final class FakeLaunchEngine {
    private let deferral: CEFLaunchDeferral
    private let pages = MockBrowserEngine(kind: .cef)
    /// The origins whose Chromium start ran, in order.
    private(set) var started: [BrowserTabOrigin] = []

    init(startup: StartupScheduler?) {
        deferral = CEFLaunchDeferral(startup: startup)
    }

    func make(_ origin: BrowserTabOrigin) -> Task<any BrowserTab, Never> {
        Task { @MainActor in
            await deferral.waitForStart(of: origin)
            started.append(origin)
            return pages.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/"), origin: origin))
        }
    }
}
