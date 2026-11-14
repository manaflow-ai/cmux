import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link on the test clock whose only frames are the pongs of the
/// controller's probes (an idle link), or, with `traffic`, one that also
/// receives a data frame every 200 ms until `trafficStops`.
private final class BeatLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let continuation: AsyncStream<LinkState>.Continuation
    let connectedPath: LinkPathKind? = .direct
    private let clock: LinkTestClock
    private let traffic: Bool
    private let trafficStops: LinkTestClock.Instant?
    private let lock = NSLock()
    private var lastPong = LinkTestClock.Instant(offset: .zero)
    private var probeTimes: [LinkTestClock.Instant] = []
    var probes: [LinkTestClock.Instant] { lock.withLock { probeTimes } }

    init(clock: LinkTestClock, traffic: Bool, trafficStops: LinkTestClock.Instant?) {
        self.clock = clock
        self.traffic = traffic
        self.trafficStops = trafficStops
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil))
    }

    private var silent: Bool { trafficStops.map { $0 < clock.now } ?? false }

    /// The last data frame: every 200 ms while traffic flows.
    private var lastTraffic: LinkTestClock.Instant? {
        guard traffic else { return nil }
        let now = clock.now
        let last = trafficStops.map { min($0, now) } ?? now
        let millis = last.offset.components.seconds * 1000 + last.offset.components.attoseconds / 1_000_000_000_000_000
        return LinkTestClock.Instant(offset: .milliseconds(millis - millis % 200))
    }

    var receivedAgo: Duration? {
        let pong = lock.withLock { lastPong }
        let last = lastTraffic.map { max($0, pong) } ?? pong
        return last.duration(to: clock.now)
    }

    var trafficAgo: Duration? { lastTraffic.map { $0.duration(to: clock.now) } ?? .seconds(3600) }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 1 }
    func probe(timeout: Duration) async throws -> UInt32? {
        let silent = lock.withLock {
            probeTimes.append(clock.now)
            return self.silent
        }
        if silent { try await Task.sleep(for: .seconds(60)) }
        lock.withLock { lastPong = clock.now }
        return 1
    }
    func close() async { continuation.finish() }
}

private final class BeatDialer: MacLinkDialer, @unchecked Sendable {
    private let clock: LinkTestClock
    private let traffic: Bool
    private let trafficStops: LinkTestClock.Instant?
    private let lock = NSLock()
    private var links: [BeatLink] = []
    var dials: Int { lock.withLock { links.count } }
    var first: BeatLink? { lock.withLock { links.first } }

    init(clock: LinkTestClock, traffic: Bool = false, trafficStops: LinkTestClock.Instant? = nil) {
        self.clock = clock
        self.traffic = traffic
        self.trafficStops = trafficStops
    }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let link = BeatLink(clock: clock, traffic: traffic, trafficStops: lock.withLock { links.isEmpty } ? trafficStops : nil)
        lock.withLock { links.append(link) }
        return link
    }
}

/// Align Keepalives: the foreground heartbeat probes an idle link on the
/// 2.5 s beats of the keepalive grid (the link ping's and the sockets'
/// instants, so the radio wakes once for all), still leaves a link with
/// traffic alone, and still redials a link that went silent within 5 s.
@MainActor
@Suite struct LinkHeartbeatAlignmentTests {
    /// The keepalive grid on the test clock (beats at whole multiples from 0).
    private static func beat(_ clock: LinkTestClock) -> KeepaliveBeat {
        KeepaliveBeat { period in
            let now = clock.now.offset
            let nowMs = now.components.seconds * 1000 + now.components.attoseconds / 1_000_000_000_000_000
            let periodMs = period.components.seconds * 1000 + period.components.attoseconds / 1_000_000_000_000_000
            return .milliseconds(periodMs - nowMs % periodMs)
        }
    }

    private func controller(_ dialer: BeatDialer, clock: LinkTestClock) -> LinkController {
        let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: clock, beat: Self.beat(clock)) { _ in "token" }
        controller.endpoint = {
            LinkEndpoint(baseURL: URL(string: "https://example.invalid")!, teamID: "t", deviceID: "d", macDeviceID: $0)
        }
        controller.send(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        return controller
    }

    private func eventually(_ condition: () -> Bool, within: Duration = .seconds(20),
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + within
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Timed out waiting for test setup or transition", sourceLocation: sourceLocation)
    }

    private func run(_ clock: LinkTestClock, until end: LinkTestClock.Instant, while going: () -> Bool = { true }) async throws {
        while clock.now < end, going() {
            clock.advance(by: .milliseconds(100))
            for _ in 0..<20 { await Task.yield() }
            try await eventually { clock.isSleeping(after: clock.now) || !going() }
        }
    }

    private func linkUp(_ controller: LinkController, _ dialer: BeatDialer) async throws {
        try await eventually { controller.phase.isConnected && dialer.first != nil }
    }

    @Test func anIdleLinkIsProbedOnEveryBeat() async throws {
        let clock = LinkTestClock()
        let dialer = BeatDialer(clock: clock)
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await linkUp(controller, dialer)
        let link = try #require(dialer.first)
        let start = clock.now
        try await run(clock, until: start.advanced(by: .seconds(60)))
        let probes = link.probes.filter { $0 > start }
        let offBeat = probes.filter {
            let ms = $0.offset.components.seconds * 1000 + $0.offset.components.attoseconds / 1_000_000_000_000_000
            return ms % 2500 != 0
        }
        print("LINK_HEARTBEAT aligned_idle_probes_per_min=\(probes.count) off_beat=\(offBeat.count)")
        #expect(offBeat.isEmpty, "probes off the 2.5 s beat: \(offBeat.map(\.offset))")
        #expect((23...24).contains(probes.count), "an idle link was probed \(probes.count) times in a minute")
    }

    @Test func aLinkWithTrafficIsStillNotProbed() async throws {
        let clock = LinkTestClock()
        let dialer = BeatDialer(clock: clock, traffic: true)
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await linkUp(controller, dialer)
        let link = try #require(dialer.first)
        let before = link.probes.count
        try await run(clock, until: clock.now.advanced(by: .seconds(60)))
        #expect(link.probes.count - before == 0)
        #expect(dialer.dials == 1)
    }

    @Test func aBusyLinkThatGoesSilentIsStillRedialedWithinFiveSeconds() async throws {
        let clock = LinkTestClock()
        let trafficStops = LinkTestClock.Instant(offset: .milliseconds(10_100))
        let dialer = BeatDialer(clock: clock, traffic: true, trafficStops: trafficStops)
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await linkUp(controller, dialer)
        // The last frame was at 10.0 s (frames every 200 ms).
        let lastFrame = LinkTestClock.Instant(offset: .seconds(10))
        try await run(clock, until: lastFrame.advanced(by: .seconds(5)), while: { dialer.dials == 1 })
        try await eventually { dialer.dials >= 2 }
        print("LINK_HEARTBEAT aligned_busy_then_silent_redial_ms=\(lastFrame.duration(to: clock.now))")
        #expect(clock.now <= lastFrame.advanced(by: .seconds(5)))
    }
}
