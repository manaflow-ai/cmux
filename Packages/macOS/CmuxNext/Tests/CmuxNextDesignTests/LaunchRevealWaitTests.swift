@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

/// `LaunchReveal.whenReady(_:within:_:)`: the launch's later-tab warm-ups wait for Home's first page (CMUX-571), but
/// a launch that never shows Home, or whose Home never gets its page, still runs them after the limit. Each runs once.
@MainActor
@Suite struct LaunchRevealWaitTests {
    @Test func theWorkRunsWhenTheRegionIsReadyAndNotAgainAtTheLimit() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock)
        var runs = 0
        reveal.whenReady(.home, within: .seconds(1)) { runs += 1 }
        #expect(runs == 0, "the work ran before Home was ready")
        reveal.markReady(.home)
        #expect(runs == 1)
        clock.advance(by: .seconds(2))
        for _ in 0..<50 { await Task.yield() }
        #expect(runs == 1, "the limit ran the work a second time")
    }

    @Test func theWorkRunsAtTheLimitWhenTheRegionNeverComes() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock)
        var runs = 0
        reveal.whenReady(.home, within: .seconds(1)) { runs += 1 }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        for _ in 0..<500 where runs == 0 { await Task.yield() }
        #expect(runs == 1, "a launch without Home never ran the work")
        reveal.markReady(.home)
        #expect(runs == 1, "Home's page ran the work a second time")
    }

    @Test func theWorkRunsAtOnceWhenTheRegionIsAlreadyReady() {
        let reveal = LaunchReveal(clock: ManualClock())
        reveal.markReady(.home)
        var runs = 0
        reveal.whenReady(.home, within: .seconds(1)) { runs += 1 }
        #expect(runs == 1)
    }
}
