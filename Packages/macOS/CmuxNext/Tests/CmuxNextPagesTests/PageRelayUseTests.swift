@testable import CmuxNextPages
import CmuxNextWakeupsTestSupport
import Testing

/// A page relay connection closes `idle` after its last use ends, and a use that begins first keeps
/// it (audit 2026-11-18 §14: relays were never closed).
@MainActor
struct PageRelayUseTests {
    private final class Rig {
        let clock = ManualClock()
        var closes = 0
        lazy var use = PageRelayUse(idle: .seconds(30), clock: clock) { [unowned self] in closes += 1 }
        func settle() async { for _ in 0..<50 { await Task.yield() } }
    }

    @Test func theLastUseEndingClosesTheRelayAfterTheIdleTime() async throws {
        let rig = Rig()
        rig.use.begin()
        rig.use.begin()
        rig.use.end()
        await rig.settle()
        #expect(rig.closes == 0)
        rig.use.end()
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(29))
        await rig.settle()
        #expect(rig.closes == 0)
        rig.clock.advance(by: .seconds(1))
        await rig.settle()
        #expect(rig.closes == 1)
    }

    @Test func aUseThatBeginsBeforeTheDeadlineKeepsTheRelay() async throws {
        let rig = Rig()
        rig.use.begin()
        rig.use.end()
        try await rig.clock.waitForSleeper()
        rig.use.begin()
        rig.clock.advance(by: .seconds(60))
        await rig.settle()
        #expect(rig.closes == 0)
        #expect(rig.use.count == 1)
    }

    @Test func pageIDsAreTheDescriptorWithoutItsPrefix() {
        #expect(PageRelayPage.id("cmux.history") == "history")
        #expect(PageRelayPage.id("feed") == "feed")
        #expect(PageRelayPage.id("cmux.Bad") == nil)
        #expect(PageRelayPage.id("") == nil)
    }
}
