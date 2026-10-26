import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// The pool follows the app's memory coordinator through one spare registration
/// (`SpareMemoryConsumer`, Chrome's spare rule), not a pressure subscription of its own: at normal
/// it keeps one spare in the default (medium) mode, a warning drops the parked spare and no new one
/// is built or parked until normal, and normal builds it again.
@MainActor @Suite(.serialized) struct PageHostPoolMemoryPressureTests {
    @Test func mediumModeAtNormalKeepsOneSpare() async {
        let memory = PageTestMemory(mode: .medium)
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = Self.pool(memory)
        defer { pool.dropSpare() }
        await Self.waitForSpare(pool, in: window)
        #expect(pool.isSpareReady)
        memory.send(.normal)
        memory.runSlices()
        #expect(pool.isSpareReady && pool.hostCount == 1, "medium mode at normal must keep one spare")
    }

    @Test func aWarningDropsTheSpareAndNothingRefillsUntilNormal() async {
        let memory = PageTestMemory()
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = Self.pool(memory)
        defer { pool.dropSpare() }
        await Self.waitForSpare(pool, in: window)

        memory.send(.warning)
        #expect(!pool.isSpareReady && pool.hostCount == 0, "a warning left the spare parked")
        pool.noteLikely()
        #expect(!pool.isBuilding && !pool.timer.isScheduled, "a build was scheduled at warning")
        memory.send(.critical)
        memory.runSlices()
        pool.noteLikely()
        #expect(pool.hostCount == 0 && !pool.timer.isScheduled, "a build was scheduled at critical")

        memory.send(.normal)
        #expect(pool.timer.isScheduled || pool.isBuilding, "back at normal the pool must build its spare again")
        await Self.waitForSpare(pool, in: window)
        #expect(pool.isSpareReady)
    }

    /// A pool made under pressure builds nothing, and an untouched host released at warning closes
    /// instead of going back to the spare slot.
    @Test func noSpareIsBuiltOrParkedUnderPressure() {
        let memory = PageTestMemory()
        memory.send(.warning)
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = Self.pool(memory)
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(!pool.timer.isScheduled && !pool.isBuilding)
        #expect(!pool.allowsSpare)
    }

    private static func pool(_ memory: PageTestMemory) -> PageHostPool {
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        return PageHostPool(memory: memory.coordinator, policy: policy, activity: { 0 }, isTrackingMenu: { false })
    }

    private static func waitForSpare(_ pool: PageHostPool, in window: NSWindow) async {
        if pool.target == nil { pool.follow(window) }
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
    }
}
