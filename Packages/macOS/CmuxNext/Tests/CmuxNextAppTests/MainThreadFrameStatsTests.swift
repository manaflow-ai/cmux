#if DEBUG
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// `debug.agent_pane fling`'s `main_*` fields: the main thread's busy time per frame, its 120 Hz
/// drops, and the sampler's stop conditions and cleanup.
struct MainThreadFrameStatsTests {
    private func frames(busyMs: [Double], refresh: Double? = 1.0 / 120) -> [MainThreadFrameStats.Frame] {
        busyMs.enumerated().map { .init(time: Double($0.offset) / 120, busy: $0.element / 1000, refresh: refresh) }
    }

    @Test func percentilesUseThePagesRoundedIndexRule() {
        // 1...20 ms: p50 is index round(19 * 0.5) = 10 (11 ms), p95 index round(18.05) = 18 (19 ms).
        let stats = MainThreadFrameStats(frames(busyMs: (1...20).reversed().map(Double.init)))
        #expect(stats.frames == 20)
        #expect(stats.busyP50Ms == 11)
        #expect(stats.busyP95Ms == 19)
        #expect(stats.busyMaxMs == 20)
    }

    @Test func busyIsReportedInMillisecondsToHundredths() {
        let stats = MainThreadFrameStats(frames(busyMs: [0.123_456, 2.345_678, 4.999_9]))
        #expect(stats.busyP50Ms == 2.35)
        #expect(stats.busyMaxMs == 5)
    }

    @Test func aFrameDropsThe120HzBudgetsItsWorkOverran() {
        #expect(MainThreadFrameStats.dropped(busyMs: 0) == 0)
        #expect(MainThreadFrameStats.dropped(busyMs: 8) == 0)
        #expect(MainThreadFrameStats.dropped(busyMs: 1000.0 / 120) == 0)
        #expect(MainThreadFrameStats.dropped(busyMs: 9) == 1)
        #expect(MainThreadFrameStats.dropped(busyMs: 2000.0 / 120) == 1)
        #expect(MainThreadFrameStats.dropped(busyMs: 17) == 2)
        #expect(MainThreadFrameStats.dropped(busyMs: 50) == 5)
        #expect(MainThreadFrameStats.dropped(busyMs: 51) == 6)
        let stats = MainThreadFrameStats(frames(busyMs: [2, 9, 17, 50]))
        #expect(stats.dropped120Hz == 1 + 2 + 5)
    }

    @Test func onlyFramesInTheScrollWindowCount() {
        // Frames tick at n / 120 s; the window keeps ticks 2...4 (busy 3, 4 and 5 ms).
        let stats = MainThreadFrameStats(frames(busyMs: [1, 2, 3, 4, 5, 60]), within: (2.0 / 120)...(4.0 / 120))
        #expect(stats.frames == 3)
        #expect(stats.busyP50Ms == 4)
        #expect(stats.busyMaxMs == 5)
        #expect(stats.dropped120Hz == 0)
    }

    @Test func theRefreshRateIsTheMedianDisplayTickAndNullWithoutOne() {
        var mixed = frames(busyMs: [1, 1, 1], refresh: 1.0 / 60)
        mixed.append(.init(time: 1, busy: 0.001, refresh: nil))
        #expect(MainThreadFrameStats(mixed).refreshHz == 60)
        let stalled = MainThreadFrameStats(frames(busyMs: [1, 1], refresh: nil))
        #expect(stalled.refreshHz == nil)
        #expect(stalled.fields["main_refresh_hz"] == JSONValue.null)
    }

    @Test func theScrollWindowIsItsFrameAgesBeforeTheReply() {
        #expect(MainThreadFrameStats.window(msAgo: [3000, 10], receivedAt: 100) == (97.0)...(99.99))
        #expect(MainThreadFrameStats.window(msAgo: [5, 5], receivedAt: 1) == (0.995)...(0.995))
        #expect(MainThreadFrameStats.window(msAgo: [], receivedAt: 1) == nil)
        #expect(MainThreadFrameStats.window(msAgo: [10], receivedAt: 1) == nil)
        #expect(MainThreadFrameStats.window(msAgo: [10, 20], receivedAt: 1) == nil, "the older frame comes first")
        #expect(MainThreadFrameStats.window(msAgo: [10, -1], receivedAt: 1) == nil)
    }

    @Test func noFramesReportZeros() {
        let stats = MainThreadFrameStats([])
        #expect(stats.fields == ["main_frames": .number(0), "main_busy_p50_ms": .number(0), "main_busy_p95_ms": .number(0),
                                 "main_busy_max_ms": .number(0), "main_dropped_frames_120hz": .number(0), "main_refresh_hz": .null])
    }

    @Test func theFieldsCarryTheStats() {
        #expect(MainThreadFrameStats(frames(busyMs: [3, 12])).fields == [
            "main_frames": .number(2), "main_busy_p50_ms": .number(12), "main_busy_p95_ms": .number(12),
            "main_busy_max_ms": .number(12), "main_dropped_frames_120hz": .number(1), "main_refresh_hz": .number(120),
        ])
    }
}

/// The sampler samples only between its start and a stop condition, and leaves nothing behind.
@MainActor
struct MainThreadFrameSamplerTests {
    @MainActor private final class FakeLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    private func scheduler() -> FrameScheduler {
        FrameScheduler.testing(makeLink: { _ in FakeLink() })
    }

    @Test func eachTickAfterTheFirstClosesAFrameUntilStop() {
        let frames = scheduler()
        let sampler = MainThreadFrameSampler(scheduler: { frames }, timeout: .seconds(60))
        #expect(frames.activeClients == [MainThreadFrameSampler.owner])
        #expect(sampler.isSampling)
        for tick in 0..<4 { frames.frameDidFire(timestamp: 10 + Double(tick) / 120, refreshInterval: 1.0 / 120) }
        #expect(sampler.frames.map(\.time) == [1, 2, 3].map { 10 + Double($0) / 120 })
        #expect(sampler.frames.allSatisfy { $0.busy >= 0 && $0.refresh == 1.0 / 120 })
        sampler.stop()
        #expect(!sampler.isSampling)
        #expect(frames.activeClients.isEmpty)
        #expect(!frames.hasLink, "the window's link pauses with its last client")
        frames.frameDidFire(timestamp: 11, refreshInterval: 1.0 / 120)
        #expect(sampler.frames.count == 3)
        sampler.stop() // idempotent
    }

    @Test func itStopsByItselfAtItsCapacity() {
        let frames = scheduler()
        let sampler = MainThreadFrameSampler(scheduler: { frames }, timeout: .seconds(60), capacity: 2)
        for tick in 0..<6 { frames.frameDidFire(timestamp: Double(tick) / 120, refreshInterval: 1.0 / 120) }
        #expect(sampler.frames.count == 2)
        #expect(!sampler.isSampling)
        #expect(frames.activeClients.isEmpty)
    }
}
#endif
