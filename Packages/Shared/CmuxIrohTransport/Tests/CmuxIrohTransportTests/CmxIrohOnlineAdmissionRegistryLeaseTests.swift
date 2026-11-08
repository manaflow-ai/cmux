import CMUXMobileCore
import CryptoKit
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohOnlineAdmissionRegistryTests {
    @Test
    func pairGrantRequiresThirtySecondsOfLeaseRemainingAtAdmission() async throws {
        let nearlyExpiredFixture = try OnlineAdmissionFixture(grantLifetime: 29)
        let nearlyExpiredBroker = OnlineAdmissionBroker(
            responses: [.success(try nearlyExpiredFixture.discovery())]
        )
        let viableFixture = try OnlineAdmissionFixture(grantLifetime: 31)
        let viableBroker = OnlineAdmissionBroker(
            responses: [.success(try viableFixture.discovery())]
        )

        #expect(
            await nearlyExpiredFixture.registry(
                broker: nearlyExpiredBroker
            ).authorizePairGrant(
                nearlyExpiredFixture.grant(),
                authenticatedPeerID: nearlyExpiredFixture.initiator.endpointID
            ) == .denied
        )
        #expect(
            await viableFixture.registry(
                broker: viableBroker
            ).authorizePairGrant(
                viableFixture.grant(),
                authenticatedPeerID: viableFixture.initiator.endpointID
            ).isAccepted
        )
    }

    @Test
    func connectivityAllowsLocallyValidGrantOffline() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.failure(.connectivity(nil))])
        let registry = fixture.registry(broker: broker)

        let authorization = await registry.authorizePairGrant(
            fixture.grant(),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        #expect(authorization.isAccepted)
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.missingAuthentication,
        .invalidAuthentication,
        .rejected(statusCode: 503, code: "unavailable"),
        .invalidResponse,
    ])
    func terminalBrokerFailuresDeny(
        _ error: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.failure(error)])
        let registry = fixture.registry(broker: broker)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func contractAndFleetMismatchDeny() async throws {
        let fixture = try OnlineAdmissionFixture()
        let contractBroker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(routeContractVersion: 2))]
        )
        let fleetBroker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(relayFleet: [fixture.otherRelayURL]))]
        )

        #expect(
            await fixture.registry(broker: contractBroker).authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        #expect(
            await fixture.registry(broker: fleetBroker).authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func missingOrAmbiguousBindingLearnsRevocationAcrossConnectivity() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery(includeInitiator: false)),
            .failure(.connectivity(nil)),
        ])
        let registry = fixture.registry(broker: broker)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        await broker.replaceResponses([.failure(.connectivity(nil))])
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        #expect(await broker.callCount() == 1)

        let ambiguousBroker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(duplicateInitiator: true))]
        )
        #expect(
            await fixture.registry(broker: ambiguousBroker).authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func onlineAcceptorPairingDisabledDeniesNewConnection() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(
            responses: [.success(try fixture.discovery(acceptorPairingEnabled: false))]
        )
        let registry = fixture.registry(broker: broker)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func leaseClosesOnRefreshRevocationWithoutTouchingEndpoint() async throws {
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
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.count() == 1)
        let activeEndpoint = try await supervisor.activeEndpoint()
        #expect(await activeEndpoint.identity() == fixture.acceptor.endpointID)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        await supervisor.deactivate()
    }

    @Test
    func relayFleetMismatchInvalidatesLeaseAsRevalidationFailure() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery(relayFleet: [fixture.otherRelayURL])),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.observedReasons() == [.revalidationFailed])
    }

    @Test
    func connectivityDoesNotCloseActiveLease() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .failure(.connectivity(nil)),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await broker.waitForCallCount(2)

        #expect(await closeRecorder.count() == 0)
        await registry.stop()
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        ),
        .rejected(statusCode: 408, code: "request_timeout"),
        .rejected(statusCode: 425, code: "too_early"),
        .rateLimited(code: "rate_limited", retryAfterSeconds: 5),
        .rejected(statusCode: 503, code: "unavailable"),
    ])
    func retryableRefreshFailureDoesNotCloseVerifiedLease(
        _ error: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .failure(error),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await broker.waitForCallCount(2)
        for _ in 0 ..< 1_024 {
            if await closeRecorder.count() > 0
                || clock.sleepingDeadlines()
                    == [fixture.now.addingTimeInterval(60)] {
                break
            }
            await Task.yield()
        }

        #expect(await closeRecorder.count() == 0)
        #expect(
            clock.sleepingDeadlines()
                == [fixture.now.addingTimeInterval(60)]
        )
        await registry.stop()
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.missingAuthentication,
        .invalidAuthentication,
        .rejected(statusCode: 403, code: "forbidden"),
        .invalidResponse,
    ])
    func definitiveRefreshFailureClosesVerifiedLease(
        _ error: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .failure(error),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await closeRecorder.waitUntilClosed()

        #expect(
            await closeRecorder.observedReasons()
                == [.revalidationFailed]
        )
    }

    @Test
    func quickTransportRegistrationRetainsMonitorForConnectionLifetime() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let connection = TestIrohConnection(
            remoteIdentity: fixture.initiator.endpointID,
            bidirectionalStreams: []
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()

        await registry.monitor(lease, connection: connection) { reason in
            await closeRecorder.close(reason: reason)
            await connection.close(errorCode: 1, reason: "lease_invalidated")
        }

        // Registering the application transport returns immediately. Revocation
        // must still close the exact live connection after that handoff returns.
        await registry.revoke(bindingID: fixture.initiator.bindingID)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.count() == 1)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func localRevokeImmediatelyClosesAndSticks() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }

        await registry.revoke(bindingID: fixture.initiator.bindingID)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.count() == 1)
        #expect(await closeRecorder.observedReasons() == [.denied])
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        #expect(await broker.callCount() == 1)
    }

    @Test
    func grantExpiryClosesLeaseAndDeniesNewAdmission() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 31)
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .failure(.connectivity(nil)),
            .failure(.connectivity(nil)),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await broker.waitForCallCount(2)
        await clock.waitUntilSleeping()
        clock.advance(by: 1)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.observedReasons() == [.leaseExpired])
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }
}

extension CmxIrohOnlineAdmissionAuthorization {
    var isAccepted: Bool { lease != nil }

    var lease: CmxIrohOnlineAdmissionLease? {
        guard case let .accepted(lease) = self else { return nil }
        return lease
    }
}
