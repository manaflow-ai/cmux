import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Real controller with only the transport replaced. The benchmark uses
/// wall time; lifecycle tests control heartbeat time. A silent link
/// deliberately ignores the probe deadline, exercising the outer FFI bound.
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
    var dials: Int { lock.withLock { count } }
    init(immediatelyConnected: Bool = true) {
        first = RecoveryLink(immediatelyConnected: immediatelyConnected)
    }
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let number = lock.withLock { count += 1; return count }
        return number == 1 ? first : RecoveryLink(immediatelyConnected: true)
    }
}

@MainActor
@Suite struct LinkRecoveryTests {
    private func controller(_ dialer: RecoveryDialer, clock: any Clock<Duration> = ContinuousClock()) -> LinkController {
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

    @Test func resumeReplacesStaleLinkWithoutWaitingForAProbe() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 }
        controller.send(.background)
        dialer.first.dropSilently()
        let oldGeneration = controller.dialGeneration
        let start = ContinuousClock.now
        controller.send(.resume)
        #expect(controller.phase == .connecting(.wireGuard, attempt: 1))
        #expect(controller.dialGeneration > oldGeneration)
        try await eventually { dialer.dials == 2 && dialer.first.isClosed }
        print("LINK_RECOVERY foreground_redial_ms=\(milliseconds(ContinuousClock.now - start))")
        #expect(dialer.first.probeCount == 1, "No probe of the stale link before redial")
    }

    @Test func backgroundBacksOffHeartbeatAndCloseStopsIt() async throws {
        let dialer = RecoveryDialer()
        let clock = LinkTestClock()
        let controller = controller(dialer, clock: clock)
        defer { controller.send(.target(nil)); clock.stop() }
        try await eventually { dialer.first.probeCount == 1 }
        controller.send(.background)
        let backgroundDeadline = clock.now.advanced(by: .seconds(15))
        try await eventually { clock.isSleeping(until: backgroundDeadline) }
        clock.advance(by: LinkController.heartbeat + .milliseconds(100))
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

    /// Run this unchanged against base and head for the Performance table.
    /// It reports actual elapsed time; the separate budget test guards policy.
    @Test func silentDropDetectionBenchmark() async throws {
        let dialer = RecoveryDialer()
        let controller = controller(dialer)
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase.isConnected }
        // Let any initial probe finish; the drop occurs just after link up,
        // covering the worst position in the heartbeat cycle on both refs.
        try await Task.sleep(for: .milliseconds(50))
        dialer.first.dropSilently()
        let start = ContinuousClock.now
        try await eventually({ dialer.dials >= 2 }, within: .seconds(26))
        let elapsed = ContinuousClock.now - start
        print("LINK_RECOVERY silent_drop_ms=\(milliseconds(elapsed))")
        #expect(elapsed <= LinkController.heartbeat + LinkController.probeTimeout + LinkController.probeGrace + .seconds(1))
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

    @Test func inactiveForegroundOnlyProbesAndIdleResumeDoesNotDial() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.background)
        #expect(machine.handle(.resume).isEmpty)
        _ = machine.handle(.target(.init(macID: "m", name: "Mac", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.handle(.resume) == [.probe(generation: machine.generation)])
    }
}
