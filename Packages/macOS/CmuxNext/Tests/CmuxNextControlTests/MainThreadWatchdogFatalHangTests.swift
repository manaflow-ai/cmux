@testable import CmuxNextControl
import CmuxNextCompat
import Foundation
import Testing

/// The watchdog thread hands every hang episode to its fatal-hang sink, so the run's record
/// is on disk from the hang threshold until the main thread answers. Unlike `onHang`, it is not rate-limited: the
/// hang the app is killed in may come minutes after one it survived. A stall shorter than the threshold gives none.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogFatalHangTests {
    /// The watch loop on its own thread with an injected clock: a 3 s stall gives one `began` with the stall's start,
    /// and the main thread going back to sleep gives one `ended`; a second hang right after gives a second pair.
    @MainActor
    @Test func everyHangBeginsAndEndsInTheFatalHangSink() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        let seen = FatalHangEvents()
        watchdog.fatalHangs = seen.sink
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        for round in 1...2 {
            let start = clock.read()
            clock.advance(by: .seconds(3))
            #expect(seen.wait { $0.began.count == round }, "round \(round): the hang never reached the sink")
            #expect(seen.events.began.last?.start == start)
            #expect(seen.events.began.last.map { $0.duration >= .seconds(2) } == true)
            #expect(seen.events.ended == round - 1, "ended before the main thread answered")
            watchdog.heartbeat(.beforeWaiting)
            #expect(seen.wait { $0.ended == round }, "round \(round): the end never reached the sink")
            watchdog.heartbeat(.afterWaiting)
        }
        #expect(seen.events.began.count == 2, "not rate-limited as onHang is")
    }

    /// A stall under the hang threshold writes nothing.
    @MainActor
    @Test func aStallShorterThanTheHangThresholdGivesNothing() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        let seen = FatalHangEvents()
        watchdog.fatalHangs = seen.sink
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        clock.advance(by: .milliseconds(1_500))
        // The watchdog checks once per threshold of real time: let it look several times.
        _ = seen.wait(for: .milliseconds(300)) { _ in false }
        watchdog.heartbeat(.beforeWaiting)
        watchdog.stop()
        #expect(seen.events.began.isEmpty)
    }
}

/// What a test's fatal-hang sink received.
private final class FatalHangEvents: Sendable {
    struct Events {
        var began: [(start: UInt64, duration: Duration)] = []
        var progressed = 0
        var ended = 0
    }

    private let state = Mutex(Events())
    var events: Events { state.withLock { $0 } }

    var sink: MainThreadWatchdog.FatalHangSink {
        MainThreadWatchdog.FatalHangSink(began: { [self] hang, start in record { $0.began.append((start, hang.duration)) } },
                                         progressed: { [self] _ in record { $0.progressed += 1 } },
                                         ended: { [self] in record { $0.ended += 1 } })
    }

    private func record(_ change: (inout Events) -> Void) {
        state.withLock { change(&$0) }
    }

    /// Polls until `done` holds or `limit` of real time passes.
    func wait(for limit: Duration = .seconds(10), until done: (Events) -> Bool) -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if done(events) { return true }
            usleep(2_000)
        }
        return done(events)
    }
}
