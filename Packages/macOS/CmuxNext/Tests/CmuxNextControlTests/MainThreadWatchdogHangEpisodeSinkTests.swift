@testable import CmuxNextControl
import CmuxNextCompat
import Testing

/// ``MainThreadWatchdog/onHangEpisode``: every hang episode, with the same sample as
/// ``MainThreadWatchdog/onHang``, which is limited to one per `hangReportInterval`
/// (the app's Sentry app hangs need each episode, p14-energy-101).
struct MainThreadWatchdogHangEpisodeSinkTests {
    @Test func everyEpisodeReachesTheEpisodeSinkWhileOnHangIsRateLimited() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangReportInterval: .seconds(300), hangAssertThreshold: nil))
        let episodes = HangDurations()
        let hangs = HangDurations()
        watchdog.onHangEpisode = { hang in episodes.values.withLock { $0.append(hang.duration) } }
        watchdog.onHang = { hang in hangs.values.withLock { $0.append(hang.duration) } }
        var lastReport: UInt64?
        let second: UInt64 = 1_000_000_000
        watchdog.reportHang(beat: 1, elapsedNanos: 2 * second, now: 10 * second, sampler: nil, lastReportNanos: &lastReport)
        watchdog.reportHang(beat: 2, elapsedNanos: 3 * second, now: 20 * second, sampler: nil, lastReportNanos: &lastReport)
        #expect(episodes.values.withLock { $0 } == [.seconds(2), .seconds(3)])
        #expect(hangs.values.withLock { $0 } == [.seconds(2)], "onHang keeps its interval")
    }

    @Test func noSinksMeansNoSample() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil))
        var lastReport: UInt64?
        watchdog.reportHang(beat: 1, elapsedNanos: 2_000_000_000, now: 1, sampler: nil, lastReportNanos: &lastReport)
        #expect(lastReport == nil)
    }
}

/// Durations a hang sink received (a class: `Mutex` cannot be captured).
private final class HangDurations: Sendable {
    let values = Mutex<[Duration]>([])
}
