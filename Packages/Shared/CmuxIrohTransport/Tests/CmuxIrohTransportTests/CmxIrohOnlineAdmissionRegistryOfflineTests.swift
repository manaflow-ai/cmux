import CMUXMobileCore
import CryptoKit
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohOnlineAdmissionRegistryTests {
    @Test
    func activeOfflinePairAcceptsUntilEarlierAttestationExpiry() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.success(try fixture.discovery())])
        let registry = fixture.registry(broker: broker)

        let authorization = await registry.authorizeOfflinePair(
            try fixture.offlinePair(initiatorLifetime: 90, acceptorLifetime: 45)
        )

        let lease = try #require(authorization.lease)
        #expect(lease.peer == CmxIrohAdmittedPeer(peer: fixture.initiator))
        #expect(lease.expiresAt == fixture.now.addingTimeInterval(45))
        #expect(await broker.callCount() == 1)
    }

    @Test
    func connectivityAllowsVerifiedOfflinePairUntilEarlierExpiry() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [.failure(.connectivity)])
        let registry = fixture.registry(broker: broker, clock: clock)
        let pair = try fixture.offlinePair(initiatorLifetime: 90, acceptorLifetime: 20)
        let lease = try #require(
            await registry.authorizeOfflinePair(pair).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(
            lease,
            connection: fixture.connection()
        ) { await closeRecorder.close() }
        await clock.waitUntilSleeping()

        #expect(clock.sleepingDeadlines() == [fixture.now.addingTimeInterval(20)])
        clock.advance(by: 20)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.count() == 1)
        #expect(await registry.authorizeOfflinePair(pair) == .denied)
        #expect(await broker.callCount() == 1)
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.missingAuthentication,
        .invalidAuthentication,
        .rejected(statusCode: 503, code: "unavailable"),
        .invalidResponse,
    ])
    func terminalBrokerFailuresDenyVerifiedOfflinePair(
        _ error: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.failure(error)])

        #expect(
            await fixture.registry(broker: broker).authorizeOfflinePair(
                try fixture.offlinePair()
            ) == .denied
        )
    }

    @Test
    func contractAndFleetMismatchDenyVerifiedOfflinePair() async throws {
        let fixture = try OnlineAdmissionFixture()
        let contractBroker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(routeContractVersion: 2))]
        )
        let fleetBroker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(relayFleet: [fixture.otherRelayURL]))]
        )

        #expect(
            await fixture.registry(broker: contractBroker).authorizeOfflinePair(
                try fixture.offlinePair()
            ) == .denied
        )
        #expect(
            await fixture.registry(broker: fleetBroker).authorizeOfflinePair(
                try fixture.offlinePair()
            ) == .denied
        )
    }

    @Test
    func pairGrantStillRequiresExactSignedTagOnline() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(initiatorTag: "substituted"))]
        )

        #expect(
            await fixture.registry(broker: broker).authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func missingOfflineBindingLearnsRevocationAcrossConnectivity() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(includeInitiator: false))]
        )
        let registry = fixture.registry(broker: broker)
        let pair = try fixture.offlinePair()

        #expect(await registry.authorizeOfflinePair(pair) == .denied)
        await broker.replaceResponses([.failure(.connectivity)])
        #expect(await registry.authorizeOfflinePair(pair) == .denied)
        #expect(await broker.callCount() == 1)
    }

    @Test
    func offlineLeaseRefreshesAtSnapshotAgeThirtyAndClosesWithoutEndpointRestart() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery(includeInitiator: false)),
        ])
        let endpoint = TestIrohEndpoint(identity: fixture.acceptor.endpointID)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 6, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [fixture.relayURL],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizeOfflinePair(
                try fixture.offlinePair(initiatorLifetime: 120, acceptorLifetime: 120)
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(
            lease,
            connection: fixture.connection()
        ) { await closeRecorder.close() }
        await clock.waitUntilSleeping()

        #expect(clock.sleepingDeadlines() == [fixture.now.addingTimeInterval(30)])
        clock.advance(by: 30)
        await closeRecorder.waitUntilClosed()

        #expect(await broker.callCount() == 2)
        #expect(await closeRecorder.count() == 1)
        let activeEndpoint = try await supervisor.activeEndpoint()
        #expect(await activeEndpoint.identity() == fixture.acceptor.endpointID)
        #expect(await endpoint.observedCloseCallCount() == 0)
        await supervisor.deactivate()
    }

    @Test
    func forgedGrantCannotInduceBrokerTraffic() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.success(try fixture.discovery())])
        let registry = fixture.registry(broker: broker)

        let authorization = await registry.authorizePairGrant(
            fixture.grant(signer: Curve25519.Signing.PrivateKey()),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        #expect(authorization == .denied)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.acceptor.endpointID
            ) == .denied
        )
        #expect(await broker.callCount() == 0)
    }

    @Test
    func onlineSnapshotIsSharedForLessThanThirtySecondsOnly() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        clock.advance(by: 29)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        #expect(await broker.callCount() == 1)

        clock.advance(by: 1)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        #expect(await broker.callCount() == 2)
    }

    @Test
    func concurrentValidAttemptsCoalesceOneRefresh() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery())],
            suspended: true
        )
        let registry = fixture.registry(broker: broker)
        let grant = fixture.grant()
        let initiatorEndpointID = fixture.initiator.endpointID

        async let first = registry.authorizePairGrant(
            grant,
            authenticatedPeerID: initiatorEndpointID
        )
        async let second = registry.authorizePairGrant(
            grant,
            authenticatedPeerID: initiatorEndpointID
        )
        await broker.waitUntilCalled()
        #expect(await broker.callCount() == 1)
        await broker.resume()

        #expect(await first.isAccepted)
        #expect(await second.isAccepted)
        #expect(await broker.callCount() == 1)
    }

    @Test
    func revokeDuringRefreshCannotAdmitTheStaleResult() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery())],
            suspended: true
        )
        let registry = fixture.registry(broker: broker)
        let grant = fixture.grant()
        let initiatorEndpointID = fixture.initiator.endpointID
        let initiatorBindingID = fixture.initiator.bindingID

        async let authorization = registry.authorizePairGrant(
            grant,
            authenticatedPeerID: initiatorEndpointID
        )
        await broker.waitUntilCalled()
        await registry.revoke(bindingID: initiatorBindingID)
        await broker.resume()

        #expect(await authorization == .denied)
    }

    @Test
    func connectivityAfterPolicyUpdateCannotAdmitStaleAuthority() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.failure(.connectivity)],
            suspended: true
        )
        let registry = fixture.registry(broker: broker)
        let grant = fixture.grant()
        let initiatorEndpointID = fixture.initiator.endpointID
        let keySet = fixture.keySet
        let replacementAcceptor = fixture.replacementAcceptor()

        async let authorization = registry.authorizePairGrant(
            grant,
            authenticatedPeerID: initiatorEndpointID
        )
        await broker.waitUntilCalled()
        await registry.update(
            keys: keySet,
            acceptor: replacementAcceptor
        )
        await broker.resume()

        #expect(await authorization == .denied)
    }

    @Test
    func staleSuccessfulMonitorRefreshCannotExtendAcrossPolicyUpdate() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(
            lease,
            connection: fixture.connection()
        ) { await closeRecorder.close() }
        await clock.waitUntilSleeping()
        await broker.suspend()

        clock.advance(by: 30)
        await broker.waitForCallCount(2)
        await registry.update(
            keys: fixture.keySet,
            acceptor: fixture.replacementAcceptor()
        )
        await broker.resume()
        for _ in 0 ..< 1_024 {
            if await closeRecorder.count() > 0 || !clock.sleepingDeadlines().isEmpty {
                break
            }
            await Task.yield()
        }

        #expect(await closeRecorder.count() == 1)
        #expect(clock.sleepingDeadlines().isEmpty)
    }

}
