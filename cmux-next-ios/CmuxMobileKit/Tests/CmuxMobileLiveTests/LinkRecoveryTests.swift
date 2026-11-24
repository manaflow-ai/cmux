import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Real controller with only the transport replaced. Every test that times
/// the heartbeat controls its clock. A silent link deliberately ignores the
/// probe deadline, exercising the outer FFI bound.
private final class RecoveryLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let continuation: AsyncStream<LinkState>.Continuation
    let connectedPath: LinkPathKind?
    private let lock = NSLock()
    private var silent = false
    private var probes = 0
    private var closed = false
    var probeCount: Int { lock.withLock { probes } }
    var isClosed: Bool { lock.withLock { closed } }

    init(immediatelyConnected: Bool) {
        connectedPath = immediatelyConnected ? .direct : nil
        (states, continuation) = AsyncStream.makeStream()
        if immediatelyConnected { connect() }
    }
    func connect() { continuation.yield(.connected(.wireGuard, .direct, rttMillis: nil)) }
    func dropSilently() { lock.withLock { silent = true } }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 1 }
    func probe(timeout: Duration) async throws -> UInt32? {
        let isSilent = lock.withLock { probes += 1; return silent }
        if isSilent { try await Task.sleep(for: .seconds(60)) }
        return 1
    }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

private final class RecoveryDialer: MacLinkDialer, @unchecked Sendable {
    let first: RecoveryLink
    private let lock = NSLock()
    private var count = 0
    private var redialSaw: Bool?
    var dials: Int { lock.withLock { count } }
    /// Read on the main actor as the second dial begins (the controller's state at the redial).
    var atRedial: (@MainActor @Sendable () -> Bool)?
    /// What ``atRedial`` returned when the second dial began.
    var sawAtRedial: Bool? { lock.withLock { redialSaw } }
    init(immediatelyConnected: Bool = true) {
        first = RecoveryLink(immediatelyConnected: immediatelyConnected)
    }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let number = lock.withLock { count += 1; return count }
        if number == 2, let atRedial {
            let saw = await atRedial()
            lock.withLock { redialSaw = saw }
        }
        return number == 1 ? first : RecoveryLink(immediatelyConnected: true)
    }
}

@MainActor
@Suite struct LinkRecoveryTests {
    private func controller(_ dialer: RecoveryDialer, clock: LinkTestClock) -> LinkController {
        let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: clock, beat: .off) { _ in "token" }
        controller.endpoint = {
            LinkEndpoint(baseURL: URL(string: "https://example.invalid")!, teamID: "t", deviceID: "d", macDeviceID: $0)
        }
        controller.send(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        return controller
    }

    private func eventually(_ condition: () -> Bool, within: Duration = .seconds(20),
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var deadline = AwakeDeadline(within)
        while !condition(), deadline.hasTimeLeft() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "Timed out waiting for test setup or transition", sourceLocation: sourceLocation)
    }

    @Test(arguments: [true, false]) func firstProbeWaitsForConnectedState(immediate: Bool) async throws {
        let dialer = RecoveryDialer(immediatelyConnected: immediate)
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { controller.link != nil }
        if !immediate {
            #expect(dialer.first.probeCount == 0)
            dialer.first.connect()
        }
        try await eventually { dialer.first.probeCount == 1 }
        #expect(controller.phase.isConnected)
    }

    /// Back from the background the redial goes out at once, beside the old
    /// link (kept as the standby and probed): a stale link never holds up the
    /// redial, and it closes when the redial wins.
    @Test func resumeRedialsAtOnceBesideTheStaleLink() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 }
        controller.send(.background)
        dialer.first.dropSilently()
        let oldGeneration = controller.dialGeneration
        controller.send(.resume)
        #expect(controller.phase == .connecting(.wireGuard, attempt: 1))
        #expect(controller.dialGeneration > oldGeneration)
        // The stale link's standby probe never answers (silent), yet the redial
        // is made and wins, and the stale link closes.
        try await eventually { dialer.dials == 2 && dialer.first.isClosed }
        #expect(controller.phase.isConnected)
    }

    @Test func shortResumeKeepsTheLiveLinkAndOnlyProbesIt() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 }
        let generation = controller.dialGeneration
        controller.send(.background)
        controller.send(.resumed(after: .seconds(1)))
        #expect(controller.phase.isConnected, "An app switch of a second shows no reconnect")
        try await eventually { dialer.first.probeCount == 2 }
        #expect(dialer.dials == 1, "No redial after a 1 s background")
        #expect(!dialer.first.isClosed)
        #expect(controller.dialGeneration == generation)
        #expect(controller.link != nil)
    }

    @Test func shortResumeOnADeadLinkKeepsItBesideARedialWithinTheQuickProbe() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        // Probes answer until the link goes silent, a millisecond in.
        let silentFrom = clock.now.advanced(by: .milliseconds(1))
        let driver = LinkClockDriver(clock: clock, controller: controller, probeAnswers: { $0 < silentFrom })
        dialer.atRedial = { [weak controller] in controller?.standbyLink != nil }
        try await eventually { dialer.first.probeCount == 1 }
        try await driver.settle()
        controller.send(.background)
        try await driver.settle()
        dialer.first.dropSilently()
        try await driver.advance(by: .milliseconds(1))
        controller.send(.resumed(after: .seconds(1)))
        #expect(controller.lastProbeTimeout == LinkController.presenceProbeTimeout)
        #expect(dialer.dials == 1)
        // The probe's bound goes on the clock when its task runs: settle first, or the advance
        // lands before that sleep starts and its deadline moves past the advance.
        try await driver.settle()
        try await driver.advance(by: LinkController.presenceProbeTimeout + LinkController.probeGrace + .milliseconds(100),
                                 until: { dialer.dials == 2 })
        try await eventually { dialer.dials == 2 }
        // The redial connects at once here, which then closes the kept link: what holds is that the
        // silent link is kept as the standby when the redial begins, not that it stays afterwards.
        #expect(dialer.sawAtRedial == true, "The silent link stays beside the redial")
    }

    @Test func backgroundBacksOffHeartbeatAndCloseStopsIt() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        let driver = LinkClockDriver(clock: clock, controller: controller)
        try await eventually { dialer.first.probeCount == 1 }
        try await driver.settle()
        controller.send(.background)
        let backgroundDeadline = clock.now.advanced(by: .seconds(15))
        try await driver.settle()
        #expect(clock.isSleeping(until: backgroundDeadline))
        // Past the foreground beat, with every timer due by then run: no probe.
        try await driver.advance(by: LinkController.heartbeat + .milliseconds(100))
        #expect(dialer.first.probeCount == 1)
        #expect(clock.isSleeping(until: backgroundDeadline))
        controller.send(.target(nil))
        try await eventually { dialer.first.isClosed }
        #expect(!clock.isSleeping(until: backgroundDeadline))
        #expect(controller.link == nil)
        #expect(dialer.dials == 1)
    }

    @Test func foregroundDetectionBudget() {
        #expect(LinkController.heartbeat + LinkController.probeTimeout + LinkController.probeGrace <= .seconds(5))
    }

    /// A silent drop just after link up (the worst point in the heartbeat
    /// cycle) is redialed with the controller's clock stopped at the budget:
    /// one heartbeat, then the probe's outer bound. A retry delay, a longer
    /// interval or a missing bound never redials. Wall time measured the
    /// runner instead: 13.4 s and 9.25 s on a loaded CI runner for a 5 s
    /// budget. The separate budget test guards the policy.
    @Test func silentDropDetectionBenchmark() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        let drop = clock.now
        let beat = drop.advanced(by: LinkController.heartbeat)
        // Link up arms the heartbeat and the first probe's bound.
        let firstBound = drop.advanced(by: LinkController.foregroundProbeTimeout + LinkController.probeGrace)
        // The first probe's answer has reached the controller (its rtt), so
        // the beat's probe is not skipped as one still in flight.
        try await eventually {
            controller.phase == .connected(.wireGuard, .direct, rttMillis: 1)
                && clock.isSleeping(untilAll: [beat, firstBound])
        }
        dialer.first.dropSilently()
        clock.advance(by: LinkController.heartbeat)
        // The beat probes the silent link; only the outer bound can end it.
        let bound = beat.advanced(by: LinkController.probeTimeout + LinkController.probeGrace)
        let nextBeat = beat.advanced(by: LinkController.heartbeat)
        try await eventually { dialer.first.probeCount == 2 && clock.isSleeping(untilAll: [bound, nextBeat]) }
        #expect(dialer.dials == 1, "No redial before the probe's bound")
        clock.advance(by: clock.now.duration(to: bound))
        try await eventually { dialer.dials >= 2 }
        print("LINK_RECOVERY silent_drop_ms=\(milliseconds(drop.duration(to: clock.now)))")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

@Suite struct LinkResumeMachineTests {
    @Test func backgroundDialIsReplacedAndLateResultsIgnored() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.background)
        #expect(machine.handle(.resume) == [.close, .dial(generation: 2, macID: "m", transport: .wireGuard)])
        #expect(machine.handle(.dialSucceeded(generation: 1, path: .direct)) == [])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))
    }

    /// A connected link back from the background is kept beside the redial;
    /// when it answers first it is the link again, nothing re-attached.
    @Test func connectedResumeKeepsTheLinkBesideTheRedial() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        _ = machine.handle(.background)
        #expect(machine.handle(.resume) == [.keepStandby, .dial(generation: 2, macID: "m", transport: .wireGuard)])
        #expect(machine.standby == 1)
        #expect(machine.handle(.standbyAlive(generation: 1, path: .direct, rttMillis: 40)) == [.promoteStandby(generation: 3)])
        #expect(machine.phase == .connected(.wireGuard, .direct, rttMillis: 40))
        // The redial's late answer is ignored.
        #expect(machine.handle(.dialSucceeded(generation: 2, path: .direct)) == [])
    }

    /// The redial wins (the old link was silent): the standby closes.
    @Test func connectedResumeRedialWinsAndClosesTheStandby() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        _ = machine.handle(.background)
        _ = machine.handle(.resume)
        #expect(machine.handle(.dialSucceeded(generation: 2, path: .direct)) == [.closeStandby])
        #expect(machine.standby == nil)
        #expect(machine.handle(.standbyAlive(generation: 1, path: .direct, rttMillis: 40)) == [])
    }

    private func connected() -> LinkMachine {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        return machine
    }

    @Test func resumeUnderShortSuspendKeepsTheLinkAndProbes() {
        for away: Duration in [.milliseconds(200), .seconds(1), .seconds(5), .seconds(29)] {
            var machine = connected()
            let generation = machine.generation
            _ = machine.handle(.background)
            #expect(machine.handle(.resumed(after: away)) == [.quickProbe(generation: generation)])
            #expect(machine.phase == .connected(.wireGuard, .direct, rttMillis: nil))
            #expect(!machine.isBackgrounded)
        }
    }

    @Test func shortResumeWithADeadLinkKeepsItBesideTheRedial() {
        var machine = connected()
        let kept = machine.generation
        _ = machine.handle(.background)
        _ = machine.handle(.resumed(after: .seconds(1)))
        let effects = machine.handle(.probeFailed(generation: kept, reason: "timeout"))
        #expect(effects == [.keepStandby, .dial(generation: kept + 1, macID: "m", transport: .wireGuard)])
        #expect(machine.standby == kept)
    }

    @Test func longResumeDialsAtOnceButKeepsTheLinkBeside() {
        for away: Duration in [.seconds(30), .seconds(300)] {
            var machine = connected()
            let kept = machine.generation
            _ = machine.handle(.background)
            #expect(machine.handle(.resumed(after: away))
                == [.keepStandby, .dial(generation: kept + 1, macID: "m", transport: .wireGuard)])
            #expect(machine.standby == kept)
            #expect(!machine.handle(.standbyAlive(generation: kept, path: .direct, rttMillis: 9)).isEmpty)
            #expect(machine.phase.isConnected)
        }
    }

    @Test func resumedDuringADialStartsItAgain() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.background)
        #expect(machine.handle(.resumed(after: .seconds(1))) == [.close, .dial(generation: 2, macID: "m", transport: .wireGuard)])
    }

    @Test func inactiveForegroundOnlyProbesAndIdleResumeDoesNotDial() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.background)
        #expect(machine.handle(.resume).isEmpty)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.handle(.resume) == [.probe(generation: machine.generation)])
    }
}
