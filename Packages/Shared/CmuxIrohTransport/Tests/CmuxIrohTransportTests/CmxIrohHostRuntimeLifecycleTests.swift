import CMUXMobileCore
import CryptoKit
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test
    func unchangedReachabilityRenewsRegistrationBeforeHintExpiry() async throws {
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
        await clock.waitUntilSleeping()
        let renewalDeadline = try #require(clock.observedSleepDeadlines().first)
        #expect(renewalDeadline < now.addingTimeInterval(60 * 60))

        clock.advance(to: renewalDeadline)
        await broker.waitForRegistrationCount(2)

        #expect(await broker.observedRegistrationCount() == 2)
        await clock.waitUntilSleepCount(2)
        await runtime.stop()
        #expect(clock.observedCancellationCount() == 1)
    }

    @Test
    func registrationRenewalHonorsBrokerRetryAfterFloor() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [
                .rateLimited(code: "slow_down", retryAfterSeconds: 300),
            ]
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
        await clock.waitUntilSleepCount(1)
        let renewalDeadline = try #require(clock.observedSleepDeadlines().first)
        clock.advance(to: renewalDeadline)
        await broker.waitForRegistrationCount(2)
        await clock.waitUntilSleepCount(2)

        let retryDeadline = try #require(clock.observedSleepDeadlines().last)
        #expect(retryDeadline >= renewalDeadline.addingTimeInterval(300))
        await runtime.stop()
    }

    @Test
    func registrationRenewalBacksOffConsecutiveFailures() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [.connectivity, .connectivity]
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
        await clock.waitUntilSleepCount(1)
        var deadline = try #require(clock.observedSleepDeadlines().last)

        clock.advance(to: deadline)
        await broker.waitForRegistrationCount(2)
        await clock.waitUntilSleepCount(2)
        let firstRetry = try #require(clock.observedSleepDeadlines().last)
        #expect(firstRetry.timeIntervalSince(deadline) >= 30)

        deadline = firstRetry
        clock.advance(to: deadline)
        await broker.waitForRegistrationCount(3)
        await clock.waitUntilSleepCount(3)
        let secondRetry = try #require(clock.observedSleepDeadlines().last)
        #expect(secondRetry.timeIntervalSince(deadline) >= 60)

        await runtime.stop()
    }

    @Test
    func successfulRegistrationRenewalResetsBackoff() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [.connectivity]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        await clock.waitUntilSleepCount(1)
        var deadline = try #require(clock.observedSleepDeadlines().last)
        clock.advance(to: deadline)
        await broker.waitForRegistrationCount(2)
        await clock.waitUntilSleepCount(2)

        deadline = try #require(clock.observedSleepDeadlines().last)
        #expect(deadline.timeIntervalSince(clock.now()) == 30)
        clock.advance(to: deadline)
        await broker.waitForRegistrationCount(3)
        await clock.waitUntilSleepCount(3)

        await broker.enqueueSubsequentRegistrationError(.connectivity)
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(4)
        await clock.waitUntilSleepCount(4)
        let resetRetry = try #require(clock.observedSleepDeadlines().last)
        #expect(resetRetry.timeIntervalSince(clock.now()) == 30)

        await runtime.stop()
    }

    @Test
    func startBindsExactRegisteredIdentityAndStopClosesIt() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["192.168.1.10:50906"]
        )
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let lanPolicies = HostRuntimeLANPolicyRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            },
            handleLANPolicy: { context, directAddresses in
                await lanPolicies.record(
                    context: context,
                    directAddresses: await directAddresses()
                )
            }
        )

        try await runtime.start()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        #expect(await broker.observedRegistrationCount() == 1)
        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 1)
        #expect(configurations.first?.secretKey == fixture.identity.secretKey)
        #expect(configurations.first?.bindPolicy == .ephemeral)
        #expect(configurations.first?.managedRelayURLs == fixture.managedRelays)
        let lan = try #require(await runtime.lanAdvertisementContext())
        #expect(lan.binding == CmxIrohBrokerBindingMetadata(binding: fixture.binding))
        #expect(lan.rendezvous == fixture.discovery.lanRendezvous)
        #expect(await runtime.localDirectAddresses() == ["192.168.1.10:50906"])
        await lanPolicies.waitForCount(1)
        #expect(await lanPolicies.contexts() == [lan])
        #expect(await lanPolicies.addresses() == [["192.168.1.10:50906"]])

        await runtime.stop()

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await runtime.lanAdvertisementContext() == nil)
    }

    @Test
    func suspendedSignOutPersistenceStopsPendingAdmissionAndBlocksRestart() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = HostRuntimeAcceptingEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let ordering = HostRuntimeSignOutOrderingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                let queued = try? await pendingRevocations.pending(
                    accountID: fixture.configuration.accountID
                ).contains(where: { $0.bindingID == bindingID })
                await ordering.record(
                    endpointClosed: await endpoint.observedCloseCallCount() == 1,
                    revocationQueued: queued == true
                )
            }
        )
        try await runtime.start()

        let blockedReceive = TestBlockingIrohReceiveStream(buffer: Data())
        var blockedEvents = await blockedReceive.blockedEvents().makeAsyncIterator()
        let connection = TestIrohConnection(
            remoteIdentity: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "b", count: 64)
            ),
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: blockedReceive,
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        await endpoint.enqueue(connection)
        _ = await blockedEvents.next()
        await store.suspendNextWrite()

        let signOut = Task { await runtime.deactivateForSignOut() }
        await store.waitUntilWriteIsSuspended()
        await connection.waitUntilClosed()

        let signingOut = await runtime.snapshot()
        #expect(signingOut.state == .signingOut)
        #expect(signingOut.bindingID == fixture.binding.bindingID)
        #expect(await connection.observedCloseCallCount() > 0)
        await #expect(throws: CmxIrohHostRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        await store.resumeSuspendedWrite()
        let preparation = await signOut.value
        #expect(preparation.wasPersisted)
        #expect(await ordering.values() == ["true:true"])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func failedSignOutPersistenceClosesHostAndQuarantinesLocalState() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )
        try await runtime.start()
        await store.failNextWrite()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(!preparation.wasPersisted)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        let quarantined = await runtime.snapshot()
        #expect(quarantined.state == .quarantined)
        #expect(quarantined.endpointID == nil)
        #expect(quarantined.bindingID == fixture.binding.bindingID)
        #expect(await runtime.lanAdvertisementContext() == nil)
        await #expect(throws: CmxIrohHostRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        let retried = await runtime.deactivateForSignOut()
        #expect(retried.wasPersisted)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func requiredBindPolicyIsForwardedToTheEndpointGeneration() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindAddress = try CmxIrohBindAddress(
            ipAddress: "127.0.0.1",
            port: 4_444
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                bindPolicy: .required(bindAddress)
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(
            await factory.observedConfigurations().first?.bindPolicy
                == .required(bindAddress)
        )
        await runtime.stop()
    }

    @Test
    func connectivityFailureUsesVerifiedCacheOnlyAfterOnlineAttempt() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let cachedPolicy = try cachedFixture.policy()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(cachedHostPolicy: cachedPolicy),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().bindingID == cachedPolicy.binding.bindingID)
        #expect(await runtime.lanAdvertisementContext()?.rendezvous == cachedPolicy.lanRendezvous)
        #expect(await bindings.count() == 0)
        await runtime.stop()
    }

    @Test
    func endpointNetworkChangeRequestsImmediateLANRefresh() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let recorder = HostRuntimeLANRefreshRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await recorder.record() }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        #expect(await recorder.waitForRefresh(timeout: .seconds(1)))

        #expect(await recorder.count() == 1)
        await runtime.stop()
    }

    @Test
    func endpointOnlineRequestsImmediateReachabilityRefresh() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let recorder = HostRuntimeLANRefreshRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await recorder.record() }
        )
        try await runtime.start()

        await endpoint.emit(.online)

        #expect(await recorder.waitForRefresh(timeout: .seconds(1)))
        await runtime.stop()
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.rejected(
            statusCode: 408,
            code: "request_timeout"
        ),
        .rejected(statusCode: 425, code: "too_early"),
        CmxIrohTrustBrokerClientError.rejected(
            statusCode: 429,
            code: "challenge_rate_limited"
        ),
        .rejected(statusCode: 503, code: "unavailable"),
    ])
    func unavailableRegistrationRefreshPreservesActiveEndpoint(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [failure]
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        await runtime.waitForRegistrationRefreshForTesting()

        #expect(await runtime.snapshot().state == .active)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await deactivations.values().isEmpty)
        await runtime.stop()
    }

}

extension CmxIrohHostRuntime {
    func waitForRegistrationRefreshForTesting() async {
        await registrationRefreshTask?.value
    }
}
