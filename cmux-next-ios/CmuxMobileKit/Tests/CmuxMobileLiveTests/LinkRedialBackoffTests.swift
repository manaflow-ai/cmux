import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link that connects at once and never answers a probe: each dial's link dies at its first
/// probe (Leo's endless reattach, 2026-11-24).
private final class DeadOnArrivalLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let continuation: AsyncStream<LinkState>.Continuation
    let connectedPath: LinkPathKind? = .direct

    init() {
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil))
    }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { throw LinkError(code: "timeout", message: "no pong") }
    func probe(timeout: Duration) async throws -> UInt32? { throw LinkError(code: "timeout", message: "no pong") }
    func close() async { continuation.finish() }
}

private final class DeadOnArrivalDialer: MacLinkDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var dials: Int { lock.withLock { count } }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        lock.withLock { count += 1 }
        return DeadOnArrivalLink()
    }
}

private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Duration.zero
    var value: Duration {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }
}

/// Connect, fail the first probe, repeat: the attempt grows with each lost link, the backoff
/// grows with it, Retry is offered, and the machine stops dialing on its own. Before the stable
/// reset each lost link redialed at attempt 1 at once, forever, and "Reconnecting" never ended.
@MainActor
@Suite struct LinkRedialBackoffTests {
    private func eventually(_ condition: () -> Bool, within: Duration = .seconds(20),
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var deadline = AwakeDeadline(within)
        while !condition(), deadline.hasTimeLeft() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Timed out waiting for the link", sourceLocation: sourceLocation)
    }

    private func waiting(_ phase: LinkMachine.Phase) -> (attempt: Int, retryIn: Duration)? {
        guard case .waiting(_, let attempt, _, let retryIn) = phase else { return nil }
        return (attempt, retryIn)
    }

    @Test func aLinkThatDiesAtItsFirstProbeBacksOffThenOffersRetryAndStops() async throws {
        let dialer = DeadOnArrivalDialer()
        let clock = LinkTestClock()
        let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: clock, beat: .off) { _ in "token" }
        controller.endpoint = {
            LinkEndpoint(baseURL: URL(string: "https://example.invalid")!, teamID: "t", deviceID: "d", macDeviceID: $0)
        }
        defer { controller.send(.target(nil)); clock.stop() }
        controller.send(.target(.init(macID: "m", name: "Mac", isOnline: true)))

        // A storm bound: the cap is 12 attempts; on base the redial never waits and the dials
        // pass this at once.
        let storm = 40
        var attempts: [Int] = []
        while true {
            try await eventually { waiting(controller.phase) != nil || dialer.dials >= storm }
            try #require(dialer.dials < storm,
                         "\(dialer.dials) dials without a wait: every lost link redials at once (the endless reattach)")
            let (attempt, retryIn) = try #require(waiting(controller.phase))
            attempts.append(attempt)
            if retryIn == .zero { break }
            let due = clock.now.advanced(by: retryIn)
            try await eventually { clock.isSleeping(until: due) }
            clock.advance(by: retryIn)
            try await eventually { waiting(controller.phase).map { $0.attempt != attempt } ?? true }
        }

        #expect(attempts == attempts.sorted() && Set(attempts).count == attempts.count,
                "The attempt grows with each lost link: \(attempts)")
        let stopped = try #require(attempts.last)
        #expect(stopped == LinkRedialPolicy.maxAttempts)
        #expect(stopped > LiveCoordinator.reconnectingAttempts)
        let banner = LiveCoordinator.waitingBanner(
            macName: "Mac", transport: .wireGuard, reason: LinkController.reason(LinkError(code: "timeout", message: "")),
            attempt: stopped, wasConnected: true, relayAvailable: true)
        #expect(banner == .connectionFailed, "Retry is offered, not an endless Reconnecting")
        #expect(controller.phase.statusLine(macName: "Mac") == "Offline")

        // Stopped: no dial on its own, however long the phone waits.
        let dialsAtStop = dialer.dials
        clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(50))
        #expect(dialer.dials == dialsAtStop)

        // The person's Retry dials once; the link dies again and it stops again, still offering Retry.
        controller.send(.open)
        try await eventually { dialer.dials == dialsAtStop + 1 && waiting(controller.phase)?.retryIn == .zero }
        #expect(waiting(controller.phase)?.attempt == LinkRedialPolicy.maxAttempts)
    }

    /// A link that stayed up past ``LinkRedialPolicy/stableAfter`` starts over at attempt 1; a short
    /// one counts as a failed attempt.
    @Test func aStableLinkStartsOverAndAShortOneCounts() {
        let now = TestUptime()
        var machine = LinkMachine(transport: .wireGuard)
        machine.uptime = { now.value }
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        now.value = .seconds(61)
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "closed"))
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))

        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        now.value += .seconds(3)
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "closed"))
        #expect(machine.phase == .connecting(.wireGuard, attempt: 2))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "closed"))
        #expect(waiting(machine.phase)?.attempt == 2)
        #expect(waiting(machine.phase)?.retryIn == .seconds(1))
    }
    /// Stopping never strands the person: the foreground, a new network path or the Mac's
    /// presence starts every attempt over with no tap (`policy::news_attempt`).
    @Test(arguments: [LinkMachine.Event.foreground, .networkChanged, .macSignaled])
    func aStoppedRedialStartsOverOnNews(news: LinkMachine.Event) {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<100 {
            switch machine.phase {
            case .connecting: _ = machine.handle(.dialFailed(generation: machine.generation, reason: "timeout"))
            case .waiting(_, _, _, let retryIn) where retryIn > .zero:
                _ = machine.handle(.retryDue(generation: machine.generation))
            default: break
            }
        }
        #expect(waiting(machine.phase)?.attempt == LinkRedialPolicy.maxAttempts)
        #expect(waiting(machine.phase)?.retryIn == .zero, "stopped")
        #expect(machine.phase.statusLine(macName: "Mac") == "Offline")
        let effects = machine.handle(news)
        #expect(effects == [.dial(generation: machine.generation, macID: "m", transport: .wireGuard)])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1), "the full set of attempts again")
    }
}
