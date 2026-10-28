import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p09-observability-109: a heartbeat close is one `daemon.unresponsive` sample, by the class of the last request
/// the app sent; the main local connection counts its daemon's ends as `stability.child_exit.daemon`.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionHeartbeatStabilityTests {
    private static func attached() -> (StabilityCounters, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        return (StabilityCounters(metrics: Metrics(runtime: runtime)), store)
    }

    private static func unresponsive(_ store: MetricsStore) -> [Int: UInt64] {
        let histogram = store.delta().histograms.first { $0.name == HistogramID.daemonUnresponsive.name }
        return Dictionary(uniqueKeysWithValues: (histogram?.buckets ?? []).map { ($0.index, $0.count) })
    }

    /// A daemon that never answers; `closed` yields at each close the heartbeat asks.
    private static func silentProbe(stability: StabilityCounters?) -> (ConnectionHeartbeat.Probe, AsyncStream<Void>) {
        let (closed, closing) = AsyncStream.makeStream(of: Void.self)
        let probe = ConnectionHeartbeat.Probe(ask: { _ in false }, close: { closing.yield() },
                                              interval: .seconds(15), misses: 1, stability: stability)
        return (probe, closed)
    }

    @Test func aCloseCountsTheLastRequestsClassOnce() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let (stability, store) = Self.attached()
        let (probe, closed) = Self.silentProbe(stability: stability)
        heartbeat.requests.sent(wire: "focus-pane")
        heartbeat.requests.sent(wire: "resize-surface")
        #expect(heartbeat.lastRequestClass == .terminalIO)
        heartbeat.start(probe)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in closed { break }
        let position = try #require(HistogramID.MethodClass.allCases.firstIndex(of: .terminalIO))
        #expect(Self.unresponsive(store) == [position: 1])
        heartbeat.stop()
    }

    @Test func aRunThatCountsNothingRecordsNothing() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let (_, store) = Self.attached()
        let (probe, closed) = Self.silentProbe(stability: nil)
        #expect(heartbeat.lastRequestClass == nil)
        heartbeat.start(probe)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in closed { break }
        #expect(Self.unresponsive(store).isEmpty, "a bridge's or a page relay's close was counted")
        heartbeat.stop()
    }

    @Test func everyMethodIdHasAClass() {
        #expect(HistogramID.MethodClass.allCases.count == 8)
        #expect(DaemonCommandName.methodClassPosition(id: DaemonCommandName("workspace.create").id) == 2, "a resource create")
        #expect(DaemonCommandName.methodClassPosition(id: DaemonCommandName(wire: "agent-unknown-route").id) == 5, "a routed agent line")
        #expect(DaemonCommandName.methodClassPosition(id: 0x7FFF) == 7, "an id the daemon does not number is other")
    }

    @Test func aDaemonEndSaysHowItEnded() {
        #expect(TransportCloseReason.daemonShutdown.daemonExit == .clean)
        #expect(TransportCloseReason.lost("EOF").daemonExit == .signal)
        #expect(TransportCloseReason.closedByClient.daemonExit == nil)
        #expect(TransportCloseReason.appFault("bad message: invalid_utf8").daemonExit == nil, "the app's own close is no daemon end")
    }

    /// The finding of the review: a stall while the person types is counted as `terminal_io`. The key goes out on a
    /// terminal view's own connection with no reply (`send`), and the heartbeat's own ask, which follows, is not the
    /// last request.
    @Test func aKeyOnATerminalConnectionThenAHeartbeatCloseCountsTerminalIO() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let (stability, store) = Self.attached()
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil, requests: heartbeat.requests)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        heartbeat.requests.sent(wire: "focus-pane")
        try transport.sendNoReply(cmd: SendInputRequest.command) { id in Data(#"{"id":\#(id),"cmd":"send"}"#.utf8) }
        #expect(try daemon.readRequest()["cmd"] as? String == "send")
        #expect(heartbeat.lastRequestClass == .terminalIO)
        _ = try? await transport.request(cmd: IdentifyRequest.commandName, timeout: .milliseconds(20), notes: false) { id in
            try WireCoding.encodeRequest(IdentifyRequest(), id: id)
        }
        #expect(heartbeat.lastRequestClass == .terminalIO, "the heartbeat's ask replaced the person's last request")

        let (probe, closed) = Self.silentProbe(stability: stability)
        heartbeat.start(probe)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in closed { break }
        let position = try #require(HistogramID.MethodClass.allCases.firstIndex(of: .terminalIO))
        #expect(Self.unresponsive(store) == [position: 1])
        heartbeat.stop()
    }
}
