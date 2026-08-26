import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test("pushed revision reconciles the Mac without re-registering")
    func pushedRevisionReconcilesMacReadOnly() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let first = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            revision: 1
        )
        let second = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 2,
            revision: 2
        )
        let broker = TestRevisionedHostBroker(
            binding: fixture.binding,
            discoveries: [first, second]
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                try fixture.relayReadyEndpoint(),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )
        try await runtime.start()

        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 1)
        #expect(
            await runtime.reconcileConnectivityRevision(2) == .refreshed
        )
        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 2)
        #expect(await bindings.count() == 2)

        #expect(
            await runtime.reconcileConnectivityRevision(1) == .refreshed
        )
        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 2)
        await runtime.stop()
    }

    /// An explicit request asks the host to re-register now instead of waiting
    /// out the hint-expiry renewal timer. The refresh must run one
    /// extra broker registration round and leave the runtime active.
    @Test("requestRegistrationRefresh runs an immediate broker round")
    func requestRegistrationRefreshRunsImmediateBrokerRound() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        #expect(await broker.observedRegistrationCount() == 1)

        await runtime.requestRegistrationRefresh()
        await broker.waitForRegistrationCount(2)

        #expect(await broker.observedRegistrationCount() == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// An explicit registration refresh that discovers the binding was REPLACED
    /// server-side (the broker returns a different binding id, the re-key
    /// newest-wins case) must fail closed into `.failed` by the time the
    /// await returns — that settled state is what the macOS composition root
    /// reads to decide it must rebuild the runtime and re-register.
    @Test("requestRegistrationRefresh settles failed when the binding was replaced")
    func requestRegistrationRefreshSettlesFailedOnReplacedBinding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let replacedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099",
            publicHintObservedAt: now,
            publicHintExpiresAt: now.addingTimeInterval(60 * 60)
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationBindings: [replacedBinding]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        #expect(await runtime.snapshot().state == .active)

        await runtime.requestRegistrationRefresh()

        #expect(await runtime.snapshot().state == .failed)
    }

    /// The explicit refresh path must be a no-op on a stopped runtime: no broker round,
    /// no state change.
    @Test("requestRegistrationRefresh is a no-op when inactive")
    func requestRegistrationRefreshNoOpWhenInactive() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        await runtime.stop()
        let countAfterStop = await broker.observedRegistrationCount()

        await runtime.requestRegistrationRefresh()
        await Task.yield()

        #expect(await broker.observedRegistrationCount() == countAfterStop)
        #expect(await runtime.snapshot().state == .inactive)
    }
}

private actor TestRevisionedHostBroker:
    CmxIrohHostBrokerServing,
    CmxConnectivityAuthorityServing
{
    private let binding: CmxIrohBrokerBinding
    private var discoveries: [CmxIrohDiscoveryResponse]
    private(set) var registrationCount = 0
    private(set) var syncCount = 0

    init(
        binding: CmxIrohBrokerBinding,
        discoveries: [CmxIrohDiscoveryResponse]
    ) {
        self.binding = binding
        self.discoveries = discoveries
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) -> CmxIrohRegistrationResponse {
        registrationCount += 1
        return CmxIrohRegistrationResponse(
            revision: discoveries.first?.revision,
            binding: binding,
            relay: .unavailable
        )
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) throws -> CmxConnectivitySyncResponse {
        syncCount += 1
        guard !discoveries.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        return CmxConnectivitySyncResponse(
            legacySnapshot: discoveries.removeFirst(),
            knownRevision: knownRevision
        )
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        guard let discovery = discoveries.first else {
            throw TestIrohTransportError.unsupported
        }
        return discovery
    }

    func issueEndpointAttestation(
        bindingID _: String
    ) throws -> CmxIrohEndpointAttestationResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) -> CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-07-10T12:00:00.000Z",
            refreshAfter: "2027-07-10T11:00:00.000Z",
            relayFleet: HostRuntimeFixture.relayURLs
        )
    }

    func revoke(bindingID _: String) {}

    func revokeStale(bindingID _: String) {}
}
