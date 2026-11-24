@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// "I feel like there are often these like dead hang loops ... these recovery processes needs to be
/// able to happen just automatically" (Leo, 2026-11-24). A hidden Chromium page whose renderer hung
/// showed its "Page unresponsive" card to nobody and stayed hung until the app quit (hq#13463). Its
/// renderer is now ended after a bound, and the page reloads once when it is next shown.
@MainActor
struct BrowserHiddenHangBoundTests {
    private final class Rig {
        let clock = ManualClock()
        var ends = 0
        var allowed = true
        lazy var bound = BrowserHiddenHangBound(owner: "test.hiddenHang", clock: clock, limit: .seconds(10),
                                                mayEnd: { [unowned self] in allowed },
                                                end: { [unowned self] in ends += 1 })

        /// Lets the timer's hop to the main actor run.
        func settle() async { for _ in 0..<50 { await Task.yield() } }
    }

    @Test func aHiddenPageThatStaysHungHasItsRendererEndedOnceTheLimitPasses() async throws {
        let rig = Rig()
        rig.bound.update(unresponsive: true, shown: false)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(9))
        await rig.settle()
        #expect(rig.ends == 0)
        rig.clock.advance(by: .seconds(1))
        await rig.settle()
        #expect(rig.ends == 1)
        #expect(!rig.bound.isPending)
    }

    @Test func aShownHungPageLeavesTheChoiceToThePerson() async throws {
        let rig = Rig()
        rig.bound.update(unresponsive: true, shown: true)
        #expect(!rig.bound.isPending)
        rig.clock.advance(by: .seconds(60))
        await rig.settle()
        #expect(rig.ends == 0)
    }

    @Test func aHungPageHiddenLaterIsBoundFromWhenItHid() async throws {
        let rig = Rig()
        rig.bound.update(unresponsive: true, shown: true)
        rig.bound.update(unresponsive: true, shown: false)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(10))
        await rig.settle()
        #expect(rig.ends == 1)
    }

    @Test func answeringAgainOrBeingShownBeforeTheLimitKeepsTheRenderer() async throws {
        let answered = Rig()
        answered.bound.update(unresponsive: true, shown: false)
        try await answered.clock.waitForSleeper()
        answered.bound.update(unresponsive: false, shown: false)
        answered.clock.advance(by: .seconds(20))
        await answered.settle()
        #expect(answered.ends == 0)

        let shown = Rig()
        shown.bound.update(unresponsive: true, shown: false)
        try await shown.clock.waitForSleeper()
        shown.bound.update(unresponsive: true, shown: true)
        shown.clock.advance(by: .seconds(20))
        await shown.settle()
        #expect(shown.ends == 0)
    }

    @Test func repeatedUpdatesDoNotPushTheEndBack() async throws {
        let rig = Rig()
        rig.bound.update(unresponsive: true, shown: false)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(6))
        rig.bound.update(unresponsive: true, shown: false)
        rig.clock.advance(by: .seconds(4))
        await rig.settle()
        #expect(rig.ends == 1)
    }

    @Test func noEndWhenAShownPageSharesTheRendererOrThePageClosed() async throws {
        let shared = Rig()
        shared.allowed = false
        shared.bound.update(unresponsive: true, shown: false)
        try await shared.clock.waitForSleeper()
        shared.clock.advance(by: .seconds(10))
        await shared.settle()
        #expect(shared.ends == 0)

        let closed = Rig()
        closed.bound.update(unresponsive: true, shown: false)
        try await closed.clock.waitForSleeper()
        closed.bound.cancel()
        closed.clock.advance(by: .seconds(10))
        await closed.settle()
        #expect(closed.ends == 0)
    }
}

/// A renderer the hidden-hang bound ended owes one reload on the next show, never a loop.
struct BrowserExitRecoveryHangTests {
    private let start = ContinuousClock.now

    @Test func aRendererEndedForHangReloadsOnceWhenShown() {
        var recovery = BrowserExitRecovery()
        #expect(recovery.endedForHang(now: start))
        #expect(recovery.takeReload(now: start))
        #expect(!recovery.takeReload(now: start), "it reloads once")
    }

    @Test func aPageThatHangsAgainRightAfterItsReloadWaitsForThePerson() {
        var recovery = BrowserExitRecovery(window: .seconds(600))
        recovery.endedForHang(now: start)
        _ = recovery.takeReload(now: start)
        #expect(!recovery.endedForHang(now: start + .seconds(30)))
        #expect(recovery.endedForHang(now: start + .seconds(601)))
    }
}
