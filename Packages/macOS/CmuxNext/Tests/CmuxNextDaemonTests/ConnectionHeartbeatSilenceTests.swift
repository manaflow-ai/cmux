import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon heartbeat asks only after a silence, 15 s while a window shows or a
/// request waits, 60 s while hidden for a connection with a notification stream, never while hidden
/// for the others, and once when a window shows or the app activates.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionHeartbeatSilenceTests {
    /// A daemon on a manual clock: the asks it got, the closes asked of it, and when it last sent a frame.
    final class Daemon: Sendable {
        private struct Counts {
            var asks = 0
            var closes = 0
            var lastInbound: Duration = .zero
        }

        private let clock: ManualClock
        private let answers: Bool
        private let counts = Mutex(Counts())
        let asked: AsyncStream<Void>
        private let asking: AsyncStream<Void>.Continuation
        let closed: AsyncStream<Void>
        private let closing: AsyncStream<Void>.Continuation

        init(clock: ManualClock, answers: Bool = true) {
            self.clock = clock
            self.answers = answers
            (asked, asking) = AsyncStream.makeStream(of: Void.self)
            (closed, closing) = AsyncStream.makeStream(of: Void.self)
        }

        var asks: Int { counts.withLock { $0.asks } }
        var closes: Int { counts.withLock { $0.closes } }

        /// The daemon sends a frame now (an event, a reply).
        func sends() {
            let now = clock.now.offset
            counts.withLock { $0.lastInbound = now }
        }

        func probe(interval: Duration = .seconds(15), hidden: Duration? = nil, misses: Int = 2) -> ConnectionHeartbeat.Probe {
            ConnectionHeartbeat.Probe(ask: { [self] _ in
                counts.withLock { $0.asks += 1 }
                if answers { sends() }
                asking.yield()
                return answers
            }, close: { [self] in
                counts.withLock { $0.closes += 1 }
                closing.yield()
            },
            silence: { [self] in clock.now.offset - counts.withLock { $0.lastInbound } },
            interval: interval, hiddenInterval: hidden, misses: misses)
        }
    }

    @Test func aHiddenConnectionWithNoStreamAsksNothing() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(ConnectionPresence(shown: false))
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe(hidden: nil))
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(daemon.asks == 0)
        #expect(clock.sleepRequests.isEmpty, "no deadline at all: \(clock.sleepRequests)")
        heartbeat.stop()
    }

    @Test func aHiddenConnectionWithAStreamAsksOncePerMinute() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(ConnectionPresence(shown: false))
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe(hidden: .seconds(60)))
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(60))
        clock.advance(by: .seconds(60))
        for await _ in daemon.asked { break }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(120))
        #expect(daemon.asks == 1)
        clock.advance(by: .seconds(60))
        for await _ in daemon.asked { break }
        try await clock.waitForSleeper()
        #expect(daemon.asks == 2)
        heartbeat.stop()
    }

    @Test func trafficEveryFiveSecondsAsksNothing() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe())
        try await clock.waitForSleeper()
        for _ in 0..<24 {
            daemon.sends()
            clock.advance(by: .seconds(5))
            // A fire found the traffic and armed for the rest of the silence.
            try await clock.waitForSleeper()
        }
        #expect(daemon.asks == 0)
        // The deadline moved lazily, once per fire: at most one sleep per 10 s of traffic, not one per frame.
        #expect(clock.sleepRequests.count <= 13, "\(clock.sleepRequests.count) sleeps")
        heartbeat.stop()
    }

    @Test func activationAsksOnce() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(ConnectionPresence())
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe())
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        heartbeat.activated()
        for await _ in daemon.asked { break }
        try await clock.waitForSleeper()
        #expect(daemon.asks == 1)
        // Answered at 5 s: the next ask waits a whole silence from there.
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(20))
        heartbeat.stop()
    }

    @Test func aWindowShowingAsksOnceAndThenOnTheShownSilence() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let presence = ConnectionPresence(shown: false)
        heartbeat.follow(presence)
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe(hidden: nil))
        clock.advance(by: .seconds(600))
        #expect(daemon.asks == 0)

        presence.update(shown: true)
        for await _ in daemon.asked { break }
        try await clock.waitForSleeper()
        #expect(daemon.asks == 1)
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(615))

        // Hidden again: the armed ask is dropped.
        presence.update(shown: false)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(daemon.asks == 1)
        heartbeat.stop()
    }

    @Test func aRequestWaitingWhileHiddenAsksOnTheShownSilence() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(ConnectionPresence(shown: false))
        let daemon = Daemon(clock: clock, answers: false)
        heartbeat.start(daemon.probe(hidden: nil, misses: 2))
        clock.advance(by: .seconds(100))
        #expect(clock.sleeperCount == 0)

        // The request went out at 100 s: the silence counts from there.
        heartbeat.requestsWaiting(true)
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(115))
        clock.advance(by: .seconds(15))
        // A wedged daemon: the first ask misses, the second goes at once and closes.
        for await _ in daemon.closed { break }
        #expect(daemon.asks == 2)
        #expect(daemon.closes == 1)

        heartbeat.requestsWaiting(false)
        heartbeat.stop()
    }

    @Test func theRequestEdgeWhileShownMovesNoDeadline() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let daemon = Daemon(clock: clock)
        heartbeat.start(daemon.probe())
        try await clock.waitForSleeper()
        let before = clock.sleepRequests.count
        heartbeat.requestsWaiting(true)
        heartbeat.requestsWaiting(false)
        #expect(clock.sleepRequests.count == before)
        #expect(clock.sleeperCount == 1)
        heartbeat.stop()
    }

    /// A daemon whose identify never answers: each ask times out on the clock after its timeout,
    /// while its other frames (events, late replies) still arrive when the test sends them.
    final class SlowDaemon: Sendable {
        enum Event: Equatable {
            case asked
            case closed
        }

        private let clock: ManualClock
        private let lastInbound = Mutex(Duration.zero)
        let events: AsyncStream<Event>
        private let emit: AsyncStream<Event>.Continuation

        init(clock: ManualClock) {
            self.clock = clock
            (events, emit) = AsyncStream.makeStream(of: Event.self)
        }

        /// The daemon sends a frame now (an event, a late reply).
        func sends() {
            let now = clock.now.offset
            lastInbound.withLock { $0 = now }
        }

        func probe(misses: Int) -> ConnectionHeartbeat.Probe {
            ConnectionHeartbeat.Probe(ask: { [self] timeout in
                emit.yield(.asked)
                try? await clock.sleep(for: timeout)
                return false
            }, close: { [self] in
                emit.yield(.closed)
            },
            silence: { [self] in clock.now.offset - lastInbound.withLock { $0 } },
            interval: .seconds(15), misses: misses)
        }
    }

    @Test func aMissFollowedByTrafficIsForgotten() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let daemon = SlowDaemon(clock: clock)
        var events = daemon.events.makeAsyncIterator()
        heartbeat.start(daemon.probe(misses: 2))
        try await clock.waitForSleeper()

        // 15 s of silence: the first ask goes out and times out at 30 s; an event arrives at 20 s.
        clock.advance(by: .seconds(15))
        let first = await events.next()
        #expect(first == .asked)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        daemon.sends()
        clock.advance(by: .seconds(10))
        try await clock.waitForSleeper()

        // A minute of traffic: fires find the daemon heard after the miss and ask nothing.
        for _ in 0..<12 {
            daemon.sends()
            clock.advance(by: .seconds(5))
            try await clock.waitForSleeper()
        }

        // Quiet again: one more miss is the first of a new run, so the next ask goes at once
        // instead of a close.
        clock.advance(by: .seconds(10))
        let second = await events.next()
        #expect(second == .asked)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        let afterSecondMiss = await events.next()
        #expect(afterSecondMiss == .asked, "a miss, a minute of traffic and one more miss closed a live daemon")
        heartbeat.stop()
    }

    @Test func aPresenceObservationEndsWithAReplacement() {
        let first = ConnectionPresence()
        let second = ConnectionPresence()
        let heartbeat = ConnectionHeartbeat(clock: ManualClock())
        heartbeat.follow(first)
        #expect(first.observerCount == 1)
        heartbeat.follow(second)
        #expect(first.observerCount == 0)
        #expect(second.observerCount == 1)
    }
}
