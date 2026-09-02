import Foundation
import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudSessionControllerTests {
    private func makeController(
        service: FakeCloudVMService = FakeCloudVMService(),
        store: InMemoryCloudDeviceIdentityStore = InMemoryCloudDeviceIdentityStore(),
        starter: FakeTunnelStarter = FakeTunnelStarter(),
        connector: FakeConnector = FakeConnector(),
        clock: TestClock = TestClock()
    ) -> CloudSessionController {
        CloudSessionController(
            service: service,
            identityStore: store,
            tunnelStarter: starter,
            connector: connector,
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "Lawrence's iPhone",
            approvalClock: clock
        )
    }

    /// Yields until `condition` holds or the budget runs out.
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 2_000 where !condition() {
            await Task.yield()
        }
    }

    @Test func appearEnrollsStartsTunnelAndListsMachines() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let store = InMemoryCloudDeviceIdentityStore()
        let starter = FakeTunnelStarter()
        let controller = makeController(service: service, store: store, starter: starter)

        controller.sectionDidAppear()
        #expect(controller.tunnel == .starting)
        await settle { controller.machines == .loaded([CloudMachine(id: "vm1", provider: "freestyle", status: "running")]) }

        let identity = try #require(store.stored)
        #expect(controller.tunnel == .ready(fingerprint: identity.fingerprint))
        #expect(service.calls.enroll.count == 1)
        #expect(service.calls.enroll[0].publicKey == identity.keyPair.publicKey)
        #expect(service.calls.enroll[0].fingerprint == identity.fingerprint)
        #expect(service.calls.enroll[0].deviceName == "Lawrence's iPhone")
        #expect(starter.startedConfigs.count == 1)
        #expect(starter.startedConfigs[0].contains("PrivateKey = \(identity.keyPair.privateKey)"))
        #expect(starter.startedConfigs[0].contains("PersistentKeepalive = 25"))
        #expect(service.calls.list == 1)
    }

    @Test func disappearDropsTunnelAndForegroundReturnRestartsOnlyWhileVisible() async {
        let starter = FakeTunnelStarter()
        let controller = makeController(starter: starter)

        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        controller.sectionDidDisappear()
        #expect(controller.tunnel == .idle)
        #expect(controller.sectionIsVisible == false)

        controller.sceneWillEnterForeground()
        #expect(controller.tunnel == .idle, "foreground alone never starts a tunnel")

        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(starter.startedConfigs.count == 2)
    }

    @Test func backgroundStopsAndForegroundRestartsWhileVisible() async {
        let starter = FakeTunnelStarter()
        let controller = makeController(starter: starter)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        controller.sceneDidEnterBackground()
        #expect(controller.tunnel == .idle)
        #expect(controller.isForeground == false)

        controller.sceneWillEnterForeground()
        #expect(controller.tunnel == .starting)
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(starter.startedConfigs.count == 2)
    }

    @Test func enrollFailureBecomesFailedPhaseAndRetryReenrolls() async {
        let service = FakeCloudVMService()
        service.enrollment = .failure(CloudAPIError.httpStatus(503, message: "provider down"))
        let controller = makeController(service: service)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        #expect(controller.tunnel == .failed(CloudSessionFailure(kind: .controlPlane(status: 503), detail: "provider down")))
        #expect(controller.machines == .idle, "no machine list without a tunnel")

        service.enrollment = .success(Fixtures.enrollment)
        controller.retryTunnel()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(service.calls.enroll.count == 2)
    }

    @Test func signedOutIsClassified() async {
        let service = FakeCloudVMService()
        service.enrollment = .failure(CloudAPIError.notSignedIn)
        let controller = makeController(service: service)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .signedOut)
    }

    @Test func tunnelStartFailureIsClassifiedAsTunnel() async {
        let starter = FakeTunnelStarter()
        starter.failure = StubError(message: "handshake timeout")
        let controller = makeController(starter: starter)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .tunnel)
        #expect(failure.detail.contains("handshake timeout"))
    }

    @Test func lockedIdentityStoreNeverMintsAndReportsIdentityFailure() async {
        let store = InMemoryCloudDeviceIdentityStore(unavailable: true)
        let service = FakeCloudVMService()
        let controller = makeController(service: service, store: store)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .identity)
        #expect(service.calls.enroll.isEmpty)
        #expect(store.stored == nil)
    }

    @Test func disappearDuringStartDiscardsTheLateTunnel() async {
        let gate = GatedTunnelStarter()
        let controller = CloudSessionController(
            service: FakeCloudVMService(),
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: gate,
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "phone"
        )
        controller.sectionDidAppear()
        await settle { gate.pending }
        controller.sectionDidDisappear()
        gate.release()
        await settle { gate.released }
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(controller.tunnel == .idle)
        #expect(controller.connection(for: CloudMachine(id: "vm", provider: "p", status: "running")) == nil)
    }

    @Test func connectionOpensLinkWithInvitationApprovalAndReusesSession() async throws {
        let service = FakeCloudVMService()
        service.attach = .success(CloudAttachEndpoint(
            route: "ws://[fd00::10]:1337/v1/link", session: "s1",
            invitation: .init(uri: "cmux-remote+invite://abc", invitationId: "inv1")
        ))
        service.approvals = [false, true]
        let connector = FakeConnector()
        let clock = TestClock()
        let controller = makeController(service: service, connector: connector, clock: clock)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let machine = CloudMachine(id: "vm1", provider: "freestyle", status: "running")
        let connection = try #require(controller.connection(for: machine))
        #expect(controller.connection(for: machine) === connection)

        connection.refreshTerminals()
        await settle { connection.terminals == .loaded([CloudTerminalSummary(id: "t1", name: "shell")]) }
        #expect(connector.connects.count == 1)
        #expect(connector.connects[0].route == "ws://[fd00::10]:1337/v1/link")
        #expect(connector.connects[0].invitation == "cmux-remote+invite://abc")
        #expect(connector.connects[0].hasTunnel)
        #expect(connector.connects[0].deviceName == "Lawrence's iPhone")
        #expect(service.calls.attach.count == 1)

        let created = await connection.createTerminal(name: "phone")
        #expect(created == "t2")
        await settle { connection.terminals.elements.count == 2 }
        #expect(connector.connects.count == 1, "the session is reused")

        let attachment = try await connection.attach(terminalID: "t2") { _ in }
        attachment.send(Data("ls\n".utf8))
        attachment.resize(cols: 60, rows: 20)
        attachment.resize(cols: 0, rows: 20)
        attachment.detach()
        let state = connector.session.state
        #expect(state.attached == "t2")
        #expect(state.sent == [Data("ls\n".utf8)])
        #expect(state.resizes.count == 1)
        #expect(state.detached == 1)

        controller.sectionDidDisappear()
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func approvalLoopPollsUntilGranted() async {
        let service = FakeCloudVMService()
        service.approvals = [false, false, true]
        let clock = TestClock()
        let loop = Task {
            await CloudMachineConnection.approveUntilGranted(service: service, machineID: "vm1", invitationId: "inv", clock: clock)
        }
        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 1 && clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 2 && clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await loop.value
        #expect(service.calls.approve.count == 3)
    }

    @Test func linkFailureIsReportedOnTheCatalog() async throws {
        let connector = FakeConnector()
        connector.failure = StubError(message: "unreachable")
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))
        connection.refreshTerminals()
        await settle { if case .failed = connection.terminals { return true } else { return false } }
        guard case .failed(let failure, let previous) = connection.terminals else { Issue.record("expected failure"); return }
        #expect(failure.kind == .link)
        #expect(previous.isEmpty)
    }
}

/// A tunnel starter that parks until released, to exercise cancellation order.
final class GatedTunnelStarter: CloudTunnelStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var _pending = false
    private var _released = false

    var pending: Bool { lock.withLock { _pending } }
    var released: Bool { lock.withLock { _released } }

    func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                continuation = c
                _pending = true
            }
        }
        lock.withLock { _released = true }
        return FakeTunnel(config: wgQuickConfig)
    }

    func release() {
        let c = lock.withLock { continuation }
        c?.resume()
    }
}

/// A manually advanced clock for the approval loop.
final class TestClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleepers: Int { lock.withLock { waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                if deadline <= current {
                    c.resume()
                } else {
                    waiters.append((deadline, c))
                }
            }
        }
    }

    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.advanced(by: duration)
            let (ready, waiting) = waiters.reduce(into: ([CheckedContinuation<Void, any Error>](), [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)]())) { acc, entry in
                if entry.deadline <= current { acc.0.append(entry.continuation) } else { acc.1.append(entry) }
            }
            waiters = waiting
            return ready
        }
        for c in due { c.resume() }
    }
}
