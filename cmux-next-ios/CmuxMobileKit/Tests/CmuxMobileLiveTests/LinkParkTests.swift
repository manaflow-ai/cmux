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
    /// The first probe waits for `releaseProbe()`, as a ping waits for its
    /// pong: the FFI call ignores cancellation.
    let holdsFirstProbe: Bool
    private let lock = NSLock()
    private var parks = 0
    private var resumes = 0
    private var probes = 0
    private var probing = 0
    private var parkedMidProbe = false
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    private var closed = false
    var parkCount: Int { lock.withLock { parks } }
    var resumeCount: Int { lock.withLock { resumes } }
    var probeCount: Int { lock.withLock { probes } }
    /// A park was asked for while a probe's ping was still unanswered.
    var parkedWhileProbing: Bool { lock.withLock { parkedMidProbe } }
    var isClosed: Bool { lock.withLock { closed } }

    init(accepts: Bool, holdsFirstProbe: Bool = false) {
        self.accepts = accepts
        self.holdsFirstProbe = holdsFirstProbe
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil))
    }

    func releaseProbe() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 1 }
    func probe(timeout: Duration) async throws -> UInt32? {
        let holds = lock.withLock { () -> Bool in
            probes += 1
            probing += 1
            return holdsFirstProbe && probes == 1
        }
        if holds {
            await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = waiting
                    return false
                }
                if now { waiting.resume() }
            }
        }
        lock.withLock { probing -= 1 }
        return 1
    }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
    func park(hold: Duration, timeout: Duration) async -> Bool {
        lock.withLock {
            parks += 1
            if probing > 0 { parkedMidProbe = true }
        }
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
    init(accepts: Bool, holdsFirstProbe: Bool = false) {
        first = ParkingLink(accepts: accepts, holdsFirstProbe: holdsFirstProbe)
    }
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

    /// A probe whose ping is still unanswered when the app leaves finishes
    /// before the park is asked for: a ping the Mac reads after it parked
    /// ends the park, and the Mac then keepalives a suspended phone. Nothing
    /// new probes the link meanwhile.
    @Test func aProbeInFlightFinishesBeforeThePark() async throws {
        let dialer = ParkingDialer(accepts: true, holdsFirstProbe: true)
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 && controller.phase.isConnected }

        controller.send(.background)
        // Give a park that does not wait for the probe the time to go out.
        await settle(within: .seconds(2)) { dialer.first.parkCount > 0 }
        dialer.first.releaseProbe()
        try await eventually { controller.isParked }
        #expect(!dialer.first.parkedWhileProbing, "the park went out while a probe was in flight")
        #expect(dialer.first.parkCount == 1)
        #expect(dialer.first.probeCount == 1, "a probe started while the park was being asked for")
    }

    /// Waits until `condition` holds or `within` passes, whichever is first;
    /// it asserts nothing.
    private func settle(within: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + within
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A notification action in the background: the parked link resumes for the request
    /// (no redial, no foreground) and parks again when it is done.
    @Test func aHoldResumesTheParkedLinkAndItsReleaseParksItAgain() async throws {
        let dialer = ParkingDialer(accepts: true)
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 && controller.phase.isConnected }
        controller.send(.background)
        try await eventually { controller.isParked }

        let hold = controller.holdAwake()
        #expect(!controller.isParked)
        #expect(dialer.first.resumeCount == 1)
        try await eventually { dialer.first.probeCount == 2 }
        #expect(controller.isBeating, "a link resumed in the background is left unwatched")

        hold.release()
        try await eventually { controller.isParked }
        #expect(dialer.first.parkCount == 2)
        #expect(dialer.dials == 1, "the parked link was redialed")
        hold.release()
        #expect(controller.isParked, "a second release counted twice")
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
        // The resume's probe failed: redial at once, the silent link kept beside the
        // redial (make before break, #49327).
        #expect(machine.handle(.probeFailed(generation: generation, reason: "timeout"))
            == [.keepStandby, .dial(generation: generation + 1, macID: "m", transport: .wireGuard)])
    }

    @Test func aLapsedParkRedialsOnResume() {
        var machine = connected()
        let generation = machine.generation
        _ = machine.handle(.background)
        _ = machine.handle(.parked(generation: generation))
        _ = machine.handle(.parkLapsed)
        // Redialed at once, the old link kept beside the redial (#50311).
        #expect(machine.handle(.resume) == [.keepStandby, .dial(generation: generation + 1, macID: "m", transport: .wireGuard)])
        #expect(machine.standby == generation)
    }

    @Test func aParkForAnOlderLinkIsIgnored() {
        var machine = connected()
        _ = machine.handle(.background)
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "peer closed the link"))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.handle(.parked(generation: machine.generation - 1)).isEmpty)
        #expect(!machine.isParked)
    }

    /// A call on the link: the phone locks and the link stays up; the call ends and it parks.
    @Test func aLinkHeldAwakeParksOnlyOnceTheHoldEnds() {
        var machine = connected()
        let generation = machine.generation
        #expect(machine.handle(.holdAwake).isEmpty)
        #expect(machine.handle(.background).isEmpty, "a link held awake was parked")
        #expect(machine.handle(.releaseAwake) == [.park(generation: generation)])
        #expect(machine.handle(.parked(generation: generation)).isEmpty)
        #expect(machine.isParked)
    }

    /// A call or a notification action in the background resumes a parked link at once;
    /// back in front with the hold still out, the link is probed, never redialed.
    @Test func aHoldResumesAParkedLinkAndTheReturnProbesIt() {
        var machine = connected()
        let generation = machine.generation
        _ = machine.handle(.background)
        _ = machine.handle(.parked(generation: generation))
        #expect(machine.handle(.holdAwake) == [.resumeParked(generation: generation)])
        #expect(!machine.isParked)
        #expect(machine.handle(.resume) == [.probe(generation: generation)])
        #expect(machine.generation == generation)
    }

    /// A hold taken while the park is being asked for takes the park back when it comes.
    @Test func aHoldDuringTheParkRequestTakesTheParkBack() {
        var machine = connected()
        let generation = machine.generation
        _ = machine.handle(.background)
        #expect(machine.handle(.holdAwake).isEmpty)
        #expect(machine.handle(.parked(generation: generation)) == [.resumeParked(generation: generation)])
        #expect(!machine.isParked)
        #expect(machine.handle(.releaseAwake) == [.park(generation: generation)])
    }
}

/// The park's background task ends once, whichever comes first: iOS's
/// expiration (the park's FFI call still out) or the release.
@MainActor
@Suite struct BackgroundTaskEndingTests {
    @Test func theExpirationEndsTheTaskOnceAndTheLateReleaseDoesNothing() {
        let ending = BackgroundTaskEnding()
        var ends = 0
        ending.arm { ends += 1 }
        ending.end()
        #expect(ends == 1, "the expiration ends the task on the spot")
        ending.end()
        #expect(ends == 1, "the release after the expiration ends nothing more")
    }

    @Test func anEndBeforeTheTaskIsArmedEndsItAsItArms() {
        let ending = BackgroundTaskEnding()
        var ends = 0
        ending.end()
        ending.arm { ends += 1 }
        ending.end()
        #expect(ends == 1)
    }
}
