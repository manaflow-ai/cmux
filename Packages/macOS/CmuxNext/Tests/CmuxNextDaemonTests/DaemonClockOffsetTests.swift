import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p09-observability-116: the heartbeat's min-RTT estimate of a remote daemon's trace clock.
@Suite(.timeLimit(.minutes(1)))
struct DaemonClockOffsetTests {
    /// The remote machine's clock is this far ahead.
    static let offset: UInt64 = 37_000_000

    /// One exchange sent at `sent` that took `out` ns to reach the daemon and `back` ns to return.
    static func exchange(sent: UInt64, out: UInt64, back: UInt64, domain: String = "monotonic") -> DaemonClockSample {
        DaemonClockSample(sentNanos: sent, remoteNanos: sent + out + offset, receivedNanos: sent + out + back, remoteDomain: domain)
    }

    @Test func theShortestRoundTripGivesTheOffsetWithinItsBound() throws {
        var filter = DaemonClockFilter()
        filter.add(Self.exchange(sent: 1_000_000_000, out: 9_000_000, back: 1_000_000))
        // The 4 ms exchange, 3 ms out and 1 ms back: its midpoint is 1 ms off.
        filter.add(Self.exchange(sent: 16_000_000_000, out: 3_000_000, back: 1_000_000))
        filter.add(Self.exchange(sent: 31_000_000_000, out: 2_000_000, back: 6_000_000))
        let estimate = try #require(filter.estimate)
        #expect(estimate.errorBoundNanos == 2_000_000)
        #expect(abs(estimate.offsetNanos - Int64(Self.offset)) <= Int64(estimate.errorBoundNanos))
        #expect(estimate.offsetNanos == Int64(Self.offset) + 1_000_000)
        #expect(estimate.measuredAtNanos == 16_004_000_000)
        #expect(estimate.remoteDomain == "monotonic")
    }

    @Test func aRemoteClockBehindGivesANegativeOffset() throws {
        var filter = DaemonClockFilter()
        filter.add(DaemonClockSample(sentNanos: 50_000_000, remoteNanos: 10_000_000, receivedNanos: 54_000_000, remoteDomain: "qpc"))
        #expect(try #require(filter.estimate).offsetNanos == -42_000_000)
    }

    @Test func itKeepsTheLastEightAndStartsOverForAnotherClock() throws {
        var filter = DaemonClockFilter()
        filter.add(Self.exchange(sent: 0, out: 500_000, back: 500_000))
        for index in 1...DaemonClockFilter.window {
            filter.add(Self.exchange(sent: UInt64(index) * 15_000_000_000, out: 2_000_000, back: 2_000_000))
        }
        #expect(filter.samples.count == DaemonClockFilter.window)
        #expect(try #require(filter.estimate).errorBoundNanos == 2_000_000, "the 1 ms exchange aged out")
        filter.add(Self.exchange(sent: 200_000_000_000, out: 5_000_000, back: 5_000_000, domain: "uptime_raw"))
        #expect(filter.samples.count == 1, "another daemon's clock")
        filter.add(DaemonClockSample(sentNanos: 10, remoteNanos: 0, receivedNanos: 5, remoteDomain: "uptime_raw"))
        #expect(filter.samples.count == 1, "an answer before its ask is not an exchange")
    }

    /// A probe that answers every ask with the next exchange.
    final class ClockProbe: Sendable {
        private let next = Mutex<[DaemonClockSample]>([])
        let asked: AsyncStream<Void>
        private let asking: AsyncStream<Void>.Continuation

        init(_ samples: [DaemonClockSample]) {
            next.withLock { $0 = samples }
            (asked, asking) = AsyncStream.makeStream(of: Void.self)
        }

        func probe() -> ConnectionHeartbeat.Probe {
            ConnectionHeartbeat.Probe(ask: { [self] _ in
                let sample = next.withLock { samples -> DaemonClockSample? in samples.isEmpty ? nil : samples.removeFirst() }
                asking.yield()
                return .answered(sample)
            }, close: {}, interval: .seconds(15), misses: 2)
        }
    }

    @Test func theHeartbeatEstimatesFromItsAsksAndForgetsThemInASleep() async throws {
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(KeepaliveGate(energy, random: { 0.5 }))
        let probe = ClockProbe([Self.exchange(sent: 1_000, out: 3_000_000, back: 1_000_000)])
        heartbeat.start(probe.probe())
        #expect(heartbeat.clockOffset() == nil)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in probe.asked { break }
        // The answer is counted before the next ask is armed.
        try await clock.waitForSleeper()
        let estimate = try #require(heartbeat.clockOffset())
        #expect(estimate.offsetNanos == Int64(Self.offset) + 1_000_000)
        #expect(estimate.errorBoundNanos == 2_000_000)

        energy.update(EnergyPolicy(suspended: true))
        #expect(heartbeat.clockOffset() == nil, "this Mac's trace clock stops in a sleep; a remote one does not")
        heartbeat.stop()
    }

    @Test func anOlderDaemonsAnswerReadsNoClock() throws {
        let line = Data(#"{"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12}}"#.utf8)
        let reading = try WireCoding.decodeResponse(ConnectionHeartbeat.TraceClockReading.self, from: line)
        #expect(reading.sample(sentNanos: 1, receivedNanos: 2) == nil)
        let clocked = Data(#"{"id":1,"ok":true,"data":{"trace_clock_ns":99,"trace_clock_domain":"monotonic"}}"#.utf8)
        let sample = try WireCoding.decodeResponse(ConnectionHeartbeat.TraceClockReading.self, from: clocked)
            .sample(sentNanos: 10, receivedNanos: 20)
        #expect(sample == DaemonClockSample(sentNanos: 10, remoteNanos: 99, receivedNanos: 20, remoteDomain: "monotonic"))
    }

    @Test func theHeartbeatAsksForTheTraceClock() throws {
        let line = try WireCoding.encodeRequest(IdentifyRequest(traceClock: true), id: 7)
        let fields = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(fields["cmd"] as? String == "identify")
        #expect(fields["trace_clock"] as? Bool == true)
        let plain = try #require(try JSONSerialization.jsonObject(with: WireCoding.encodeRequest(IdentifyRequest(), id: 7)) as? [String: Any])
        #expect(plain["trace_clock"] == nil, "the handshake's identify keeps its shape")
    }
}
