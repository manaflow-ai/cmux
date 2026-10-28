import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// A warm page can finish its first paint without remaining visible to WebKit while parked.
@MainActor @Suite(.serialized) struct PageHostPoolVisibilityTests {
    @Test func chromiumPagesDoNotStartAnUnusedWebKitSpare() {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        var decision = PageEngineDecision.chromium
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                activity: { 0 }, isTrackingMenu: { false }, engineDecision: { _, _ in decision })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(!pool.shouldBuild)
        #expect(!pool.timer.isScheduled)
        #expect(pool.hostCount == 0)

        // A real WebKit fallback or preference still gets the existing warm path.
        decision = .webKit(.personChoseWebKit)
        pool.noteLikely()
        #expect(pool.shouldBuild)
        #expect(pool.timer.isScheduled)
        decision = .chromium
        pool.noteLikely()
        #expect(!pool.timer.isScheduled, "switching engines cancels the queued WebKit build")
    }

    @Test func parkedPageSleepsAfterPaintAndWakesOnClaim() async throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                policy: policy, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        pool.follow(window)
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        let spare = try #require(pool.spare)
        _ = await PageTestWait.value("spare painted") { (done: @escaping (Bool) -> Void) in
            spare.whenPainted { done(true) }
        }
        #expect(spare.isHidden, "zero opacity alone leaves the parked renderer active")

        let claimed = try #require(pool.claim(.settings, routes: [], window: window, focus: false))
        #expect(claimed === spare, "opening must keep the loaded renderer")
        #expect(!claimed.isHidden, "the spare must wake before its claim runs")
        #expect(claimed.loaded)

        pool.release(claimed)
        if !pool.isSpareReady {
            _ = await PageTestWait.value("recycled spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        #expect(pool.spare === claimed)
        #expect(claimed.isHidden, "an untouched page returned to the pool must sleep again")
    }
}
