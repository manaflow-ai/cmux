import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link whose Mac sends a frame every 200 ms (a streaming turn, terminal
/// output) on the test clock, until `framesStop`; after that it goes silent
/// and its probe never answers (only the controller's outer bound ends it).
private final class TrafficLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let continuation: AsyncStream<LinkState>.Continuation
    let connectedPath: LinkPathKind? = .direct
    private let clock: LinkTestClock
    private let framesStop: LinkTestClock.Instant?
    private let lock = NSLock()
    private var probes = 0
    var probeCount: Int { lock.withLock { probes } }

    init(clock: LinkTestClock, framesStop: LinkTestClock.Instant?) {
        self.clock = clock
        self.framesStop = framesStop
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil))
    }

    private var isSilent: Bool {
        guard let framesStop else { return false }
        return framesStop < clock.now
    }

    /// The time since the last 200 ms frame (frames stop at `framesStop`).
    var receivedAgo: Duration? {
        let now = clock.now
        let last = framesStop.map { min($0, now) } ?? now
        let millis = Int64(last.offset.components.seconds) * 1000
            + Int64(last.offset.components.attoseconds / 1_000_000_000_000_000)
        return now.offset - .milliseconds(millis - millis % 200)
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 1 }
    func probe(timeout: Duration) async throws -> UInt32? {
        let silent = lock.withLock { probes += 1; return isSilent }
        if silent { try await Task.sleep(for: .seconds(60)) }
        return 1
    }
    func close() async { continuation.finish() }
}

private final class TrafficDialer: MacLinkDialer, @unchecked Sendable {
    private let clock: LinkTestClock
    private let framesStop: LinkTestClock.Instant?
    private let lock = NSLock()
    private var links: [TrafficLink] = []
    var dials: Int { lock.withLock { links.count } }
    var first: TrafficLink? { lock.withLock { links.first } }

    init(clock: LinkTestClock, framesStop: LinkTestClock.Instant? = nil) {
        self.clock = clock
        self.framesStop = framesStop
    }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let link = TrafficLink(clock: clock, framesStop: lock.withLock { links.isEmpty } ? framesStop : nil)
        lock.withLock { links.append(link) }
        return link
    }
}

/// The foreground heartbeat probes a link only when it has been quiet for a
/// beat: a link delivering frames is proven alive by them, and its probes
/// were a ping, a pong and a main-actor turn every 2.5 s for nothing
/// (Leo 2026-11-14: "decrease battery drain/ram on iOS app").
@MainActor
@Suite struct LinkHeartbeatTrafficTests {
    private func controller(_ dialer: TrafficDialer, clock: LinkTestClock) -> LinkController {
        let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: clock) { _ in "token" }
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

    /// Moves the clock to `end` in 100 ms steps, letting every woken timer
    /// run and the heartbeat re-arm before the next step.
    private func run(_ clock: LinkTestClock, until end: LinkTestClock.Instant, while going: () -> Bool = { true }) async throws {
        while clock.now < end, going() {
            clock.advance(by: .milliseconds(100))
            for _ in 0..<20 { await Task.yield() }
            try await eventually { clock.isSleeping(after: clock.now) || !going() }
        }
    }

    private func linkUp(_ controller: LinkController, _ clock: LinkTestClock) async throws {
        // The link-up probe answered and the first beat is armed.
        try await eventually {
            controller.phase == .connected(.wireGuard, .direct, rttMillis: 1)
                && clock.isSleeping(until: clock.now.advanced(by: LinkController.heartbeat))
        }
    }

    @Test func aLinkDeliveringFramesIsNotProbed() async throws {
        let clock = LinkTestClock()
        let dialer = TrafficDialer(clock: clock)
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await linkUp(controller, clock)
        let link = try #require(dialer.first)
        let before = link.probeCount
        try await run(clock, until: clock.now.advanced(by: .seconds(60)))
        let perMinute = link.probeCount - before
        print("LINK_HEARTBEAT busy_link_probes_per_min=\(perMinute)")
        #expect(perMinute == 0, "A link delivering a frame every 200 ms was probed \(perMinute) times in a minute")
        #expect(controller.phase.isConnected)
        #expect(dialer.dials == 1)
    }

    /// The 5 s foreground bound holds from the Mac's last frame: a link that
    /// was busy, then went silent, is redialed by then.
    @Test func aBusyLinkThatGoesSilentIsRedialedWithinFiveSeconds() async throws {
        let clock = LinkTestClock()
        let framesStop = LinkTestClock.Instant(offset: .seconds(10))
        let dialer = TrafficDialer(clock: clock, framesStop: framesStop)
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await linkUp(controller, clock)
        try await run(clock, until: framesStop.advanced(by: .seconds(5)), while: { dialer.dials == 1 })
        try await eventually { dialer.dials >= 2 }
        print("LINK_HEARTBEAT busy_then_silent_redial_ms=\(framesStop.duration(to: clock.now))")
        #expect(clock.now <= framesStop.advanced(by: .seconds(5)))
    }
}
