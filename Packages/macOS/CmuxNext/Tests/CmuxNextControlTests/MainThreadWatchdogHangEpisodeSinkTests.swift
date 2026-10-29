@testable import CmuxNextControl
import CmuxNextCompat
import Foundation
import Testing

/// ``MainThreadWatchdog/onHangEpisode``: each hang episode's tracker reports (began, the doubling
/// checkpoints, ended with the exact length), not limited by `hangReportInterval` as
/// ``MainThreadWatchdog/onHang`` is (the app's Sentry app hangs).
struct MainThreadWatchdogHangEpisodeSinkTests {
    private static let second: UInt64 = 1_000_000_000

    @Test func everyEpisodeReachesTheEpisodeSinkWhileOnHangIsRateLimited() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangReportInterval: .seconds(300), hangAssertThreshold: nil))
        let episodes = EpisodeEvents()
        let hangs = EpisodeEvents()
        watchdog.onHangEpisode = { episodes.add($0) }
        watchdog.onHang = { hangs.add(.blocked($0, previous: nil)) }
        var state = MainThreadWatchdog.HangState(episodes: HangEpisodeTracker(hangNanos: 2 * Self.second))
        watchdog.reportHang(beat: 1, elapsedNanos: 2 * Self.second, now: 10 * Self.second, sampler: nil, crashKeys: nil, trace: nil, state: &state)
        state.episodeReport = nil // the first episode ended
        watchdog.reportHang(beat: 2, elapsedNanos: 3 * Self.second, now: 20 * Self.second, sampler: nil, crashKeys: nil, trace: nil, state: &state)
        #expect(episodes.summaries == [.blocked(.seconds(2), previous: nil), .blocked(.seconds(3), previous: nil)])
        #expect(hangs.summaries.count == 1, "onHang keeps its interval")
    }

    @Test func noSinksMeansNoSample() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil))
        var state = MainThreadWatchdog.HangState(episodes: HangEpisodeTracker(hangNanos: 2 * Self.second))
        watchdog.reportHang(beat: 1, elapsedNanos: 2 * Self.second, now: 1, sampler: nil, crashKeys: nil, trace: nil, state: &state)
        #expect(state.lastReportNanos == nil)
        #expect(state.episodeReport == nil)
    }

    /// The watch loop itself, on the watchdog's own clock: one 8.5 s stall is reported at 2 s,
    /// at the 4 s and 8 s checkpoints (each with the duration of the report before it), then
    /// ended with the exact length the main thread measured and the last report.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aLongStallReportsItsCheckpointsThenItsExactEnd() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        let events = EpisodeEvents()
        watchdog.onHangEpisode = { events.add($0) }
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        clock.advance(by: .seconds(2))
        #expect(events.waitForCount(1))
        clock.advance(by: .seconds(2))
        #expect(events.waitForCount(2))
        clock.advance(by: .seconds(4))
        #expect(events.waitForCount(3))
        clock.advance(by: .milliseconds(500))
        watchdog.heartbeat(.beforeWaiting) // the main thread answers after 8.5 s
        #expect(events.waitForCount(4))
        #expect(events.summaries == [.blocked(.seconds(2), previous: nil), .blocked(.seconds(4), previous: .seconds(2)),
                                     .blocked(.seconds(8), previous: .seconds(4)), .ended(.milliseconds(8_500), lastReport: .seconds(8))])
    }
}

/// An episode event without its stacks, comparable.
enum EpisodeSummary: Equatable {
    case blocked(Duration, previous: Duration?)
    case ended(Duration, lastReport: Duration?)
}

/// Episode events a sink received (a class: `Mutex` cannot be captured).
final class EpisodeEvents: Sendable {
    private let events = Mutex<[MainThreadWatchdog.HangEpisodeEvent]>([])

    func add(_ event: MainThreadWatchdog.HangEpisodeEvent) { events.withLock { $0.append(event) } }

    var summaries: [EpisodeSummary] {
        events.withLock { $0 }.map { event -> EpisodeSummary in
            switch event {
            case let .blocked(hang, previous): return .blocked(hang.duration, previous: previous)
            case let .ended(duration, lastReport): return .ended(duration, lastReport: lastReport?.duration)
            }
        }
    }

    /// Waits (real time, bounded) until the watchdog thread delivered `count` events.
    func waitForCount(_ count: Int) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while events.withLock({ $0.count }) < count, ContinuousClock.now < deadline { usleep(2_000) }
        return events.withLock { $0.count } >= count
    }
}
