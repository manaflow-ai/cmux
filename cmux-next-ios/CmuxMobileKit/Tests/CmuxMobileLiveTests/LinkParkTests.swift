import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link the Mac can hold while the app is suspended (PROTOCOL.md "Parked
/// link"), or one that refuses (an older Mac).
private final class ParkingLink: ParkableMacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let continuation: AsyncStream<LinkState>.Continuation
    let connectedPath: LinkPathKind? = .direct
    let accepts: Bool
    private let lock = NSLock()
    private var parks = 0
    private var resumes = 0
    private var probes = 0
    private var closed = false
    var parkCount: Int { lock.withLock { parks } }
    var resumeCount: Int { lock.withLock { resumes } }
    var probeCount: Int { lock.withLock { probes } }
    var isClosed: Bool { lock.withLock { closed } }

    init(accepts: Bool) {
        self.accepts = accepts
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil))
    }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 1 }
    func probe(timeout: Duration) async throws -> UInt32? {
        lock.withLock { probes += 1 }
        return 1
    }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
    func park(hold: Duration, timeout: Duration) async -> Bool {
        lock.withLock { parks += 1 }
        return accepts
    }
    func resumeParked() -> Bool {
        lock.withLock { resumes += 1 }
        return accepts
    }
}

private final class ParkingDialer: MacLinkDialer, @unchecked Sendable {
    let first: ParkingLink
    private let lock = NSLock()
    private var count = 0
    var dials: Int { lock.withLock { count } }
    init(accepts: Bool) { first = ParkingLink(accepts: accepts) }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let number = lock.withLock { count += 1; return count }
        return number == 1 ? first : ParkingLink(accepts: first.accepts)
    }
}

@MainActor
@Suite struct LinkParkTests {
    private func controller(_ dialer: ParkingDialer, clock: any Clock<Duration>) -> LinkController {
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

    /// The partial link: the app leaves with a live link, the Mac parks it,
    /// nothing probes it while away (a ping would end the Mac's park), and
    /// on return it is roamed and probed once, never redialed.
    @Test func aParkedLinkComesBackWithoutARedial() async throws {
        let dialer = ParkingDialer(accepts: true)
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 && controller.phase.isConnected }
        let generation = controller.dialGeneration

        controller.send(.background)
        try await eventually { controller.isParked }
        #expect(dialer.first.parkCount == 1)
        // No heartbeat is left to probe the parked link while away.
        #expect(!controller.isBeating, "a parked link keeps its heartbeat")
        clock.advance(by: LinkController.backgroundHeartbeat * 4)
        #expect(dialer.first.probeCount == 1, "a parked link was probed while away")

        controller.send(.resume)
        try await eventually { dialer.first.probeCount == 2 }
        #expect(dialer.first.resumeCount == 1)
        #expect(dialer.dials == 1, "a parked link was redialed")
        #expect(!dialer.first.isClosed)
        #expect(controller.dialGeneration == generation)
        #expect(controller.phase.isConnected)
        #expect(!controller.isParked)
    }

    /// An older Mac refuses the park: the link closes on silence there, so
    /// the return redials at once, as before parking existed.
    @Test func aRefusedParkRedialsOnReturn() async throws {
        let dialer = ParkingDialer(accepts: false)
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 && controller.phase.isConnected }
        controller.send(.background)
        try await eventually { dialer.first.parkCount == 1 }
        #expect(!controller.isParked)
        controller.send(.resume)
        try await eventually { dialer.dials == 2 && dialer.first.isClosed }
        #expect(dialer.first.resumeCount == 0)
    }
}

@Suite struct LinkParkMachineTests {
    private func connected() -> LinkMachine {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        return machine
    }

    @Test func aParkedLinkResumesByProbeNotRedial() {
        var machine = connected()
        let generation = machine.generation
        #expect(machine.handle(.background) == [.park(generation: generation)])
        #expect(machine.handle(.parked(generation: generation)).isEmpty)
        #expect(machine.isParked)
        #expect(machine.handle(.macSignaled).isEmpty, "nothing probes a parked link")
        #expect(machine.handle(.foreground).isEmpty, "nothing probes a parked link")
        #expect(machine.handle(.resume) == [.resumeParked(generation: generation)])
        #expect(machine.phase.isConnected && machine.generation == generation && !machine.isParked)
        // The resume's probe failed: redial at once.
        #expect(machine.handle(.probeFailed(generation: generation, reason: "timeout"))
            == [.close, .dial(generation: generation + 1, macID: "m", transport: .wireGuard)])
    }

    @Test func aLapsedParkRedialsOnResume() {
        var machine = connected()
        let generation = machine.generation
        _ = machine.handle(.background)
        _ = machine.handle(.parked(generation: generation))
        _ = machine.handle(.parkLapsed)
        #expect(machine.handle(.resume) == [.close, .dial(generation: generation + 1, macID: "m", transport: .wireGuard)])
    }

    @Test func aParkForAnOlderLinkIsIgnored() {
        var machine = connected()
        _ = machine.handle(.background)
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "peer closed the link"))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.handle(.parked(generation: machine.generation - 1)).isEmpty)
        #expect(!machine.isParked)
    }
}
