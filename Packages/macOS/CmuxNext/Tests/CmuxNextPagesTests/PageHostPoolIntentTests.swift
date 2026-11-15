import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// CMUX-571 (ram-baseline): the parked Settings spare cost about 106 MB at rest (91 MB of WebKit processes) because
/// launch built it. Now no spare exists until a sign of intent (a menu or palette open, ⌘ alone, a pointer on the
/// Settings, History or Cloud item), which builds it at once, and an idle limit with no intent or claim frees it.
@MainActor @Suite(.serialized, .closesItsWindows) struct PageHostPoolIntentTests {
    /// The launch path: the pool starts with a main window and learns of no intent, so it builds nothing, also
    /// once the input has been idle past its warmup delay.
    @Test func aStartedPoolBuildsNoSpareBeforeASignOfIntent() async throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = Self.pool()
        defer { pool.dropSpare() }
        pool.start(isMainWindow: { $0 === window }, fallback: { _ in nil })
        try await Task.sleep(for: .milliseconds(300)) // well past idleInput (5 ms): an armed build would have started
        #expect(pool.target === window)
        #expect(!pool.isLikely && !pool.isBuilding && pool.hostCount == 0, "the pool built a spare at launch with no sign of intent")
    }

    /// A sign of intent builds the spare at once, even while a menu tracks and the input is never idle (the old
    /// idle-input warmup waited past the menu's click, so its row opened cold).
    @Test func aSignOfIntentBuildsTheSpareDuringAMenu() async {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        var input: UInt64 = 0
        let pool = Self.pool(activity: { input &+= 1; return input }, isTrackingMenu: { true })
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteIntent()
        #expect(pool.isBuilding, "a sign of intent waited for idle input")
        await Self.waitReady(pool)
        #expect(pool.isSpareReady)
    }

    /// The idle limit with no intent or claim frees the spare, and none is built again until the next sign.
    @Test func theIdleLimitFreesTheSpareUntilTheNextSign() async throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let pool = Self.pool()
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteIntent()
        await Self.waitReady(pool)
        pool.idleLimit = .milliseconds(100)
        pool.noteIntent() // a sign on a built spare only pushes the limit back
        #expect(pool.isSpareReady)
        for _ in 0..<200 where pool.hostCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pool.hostCount == 0 && !pool.isLikely, "the idle limit passed and the spare stayed")
        try await Task.sleep(for: .milliseconds(300)) // past idleInput: no rebuild may be armed
        #expect(pool.hostCount == 0 && !pool.isBuilding, "a freed spare was built again with no sign of intent")
        pool.noteIntent()
        await Self.waitReady(pool)
        #expect(pool.isSpareReady, "the next sign of intent did not build the spare again")
    }

    static func pool(activity: @escaping () -> UInt64 = { 0 }, isTrackingMenu: @escaping () -> Bool = { false }) -> PageHostPool {
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        return PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), policy: policy,
                            activity: activity, isTrackingMenu: isTrackingMenu)
    }

    static func waitReady(_ pool: PageHostPool) async {
        guard !pool.isSpareReady else { return }
        _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
            pool.onSpareReady = { _ in done(true) }
        }
    }
}
