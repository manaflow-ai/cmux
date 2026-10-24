import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// The pool reacts to the app's one memory pressure service (`AppServices.memoryPressure`), not a
/// kernel source of its own: a warning drops the parked spare, a normal level keeps it.
@MainActor @Suite(.serialized) struct PageHostPoolMemoryPressureTests {
    @Test func aWarningFromTheSharedEventsDropsTheSpare() async {
        let source = ManualMemoryPressureSource()
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: source), policy: policy,
                                activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        #expect(pool.isSpareReady)
        source.send(.normal)
        #expect(pool.isSpareReady, "a normal level keeps the spare")
        source.send(.warning)
        #expect(!pool.isSpareReady && pool.hostCount == 0, "a warning from the shared events left the spare parked")
    }
}
