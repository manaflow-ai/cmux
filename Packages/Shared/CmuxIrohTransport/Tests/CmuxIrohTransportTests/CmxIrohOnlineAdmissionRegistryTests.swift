import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohOnlineAdmissionRegistryTests {
    @Test
    func activeSignedBindingAcceptsAfterOnlineValidation() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.success(try fixture.discovery())])
        let registry = fixture.registry(broker: broker)

        let authorization = await registry.authorizePairGrant(
            fixture.grant(),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        let lease = try #require(authorization.lease)
        #expect(lease.peer == CmxIrohAdmittedPeer(peer: fixture.initiator))
        #expect(lease.expiresAt == fixture.now.addingTimeInterval(300))
        #expect(await broker.callCount() == 1)
    }

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
        _ = await registry.monitor(lease) { await closeRecorder.close() }
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
        _ = await registry.monitor(lease) { await closeRecorder.close() }
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

        async let first = registry.authorizePairGrant(
            fixture.grant(),
            authenticatedPeerID: fixture.initiator.endpointID
        )
        async let second = registry.authorizePairGrant(
            fixture.grant(),
            authenticatedPeerID: fixture.initiator.endpointID
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

        async let authorization = registry.authorizePairGrant(
            fixture.grant(),
            authenticatedPeerID: fixture.initiator.endpointID
        )
        await broker.waitUntilCalled()
        await registry.revoke(bindingID: fixture.initiator.bindingID)
        await broker.resume()

        #expect(await authorization == .denied)
    }

    @Test
    func connectivityAllowsLocallyValidGrantOffline() async throws {
        let fixture = try OnlineAdmissionFixture()
        let broker = OnlineAdmissionBroker(responses: [.failure(.connectivity)])
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
            .failure(.connectivity),
        ])
        let registry = fixture.registry(broker: broker)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        await broker.replaceResponses([.failure(.connectivity)])
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
        _ = await registry.monitor(lease) {
            await closeRecorder.close()
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
    func connectivityDoesNotCloseActiveLease() async throws {
        let fixture = try OnlineAdmissionFixture()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .failure(.connectivity),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        _ = await registry.monitor(lease) {
            await closeRecorder.close()
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 30)
        await broker.waitForCallCount(2)

        #expect(await closeRecorder.count() == 0)
        await registry.stop()
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
        _ = await registry.monitor(lease) {
            await closeRecorder.close()
        }

        await registry.revoke(bindingID: fixture.initiator.bindingID)
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.count() == 1)
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
        let fixture = try OnlineAdmissionFixture(grantLifetime: 20)
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [.failure(.connectivity)])
        let registry = fixture.registry(broker: broker, clock: clock)
        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        _ = await registry.monitor(lease) {
            await closeRecorder.close()
        }
        await clock.waitUntilSleeping()

        clock.advance(by: 20)
        await closeRecorder.waitUntilClosed()

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }
}

private extension CmxIrohOnlineAdmissionAuthorization {
    var isAccepted: Bool { lease != nil }

    var lease: CmxIrohOnlineAdmissionLease? {
        guard case let .accepted(lease) = self else { return nil }
        return lease
    }
}

private actor OnlineAdmissionBroker: CmxIrohRegistryServing {
    private var responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>]
    private var calls = 0
    private var suspended: Bool
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>],
        suspended: Bool = false
    ) {
        self.responses = responses
        self.suspended = suspended
    }

    func discover() async throws -> CmxIrohDiscoveryResponse {
        calls += 1
        releaseCallWaiters()
        if suspended {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        guard !responses.isEmpty else { throw CmxIrohTrustBrokerClientError.invalidResponse }
        return try responses.removeFirst().get()
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) async throws -> CmxIrohPairGrantResponse {
        throw CmxIrohTrustBrokerClientError.invalidResponse
    }

    func callCount() -> Int { calls }

    func waitUntilCalled() async { await waitForCallCount(1) }

    func waitForCallCount(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func resume() {
        suspended = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func replaceResponses(
        _ responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>]
    ) {
        self.responses = responses
    }

    private func releaseCallWaiters() {
        let ready = callWaiters.filter { calls >= $0.0 }
        callWaiters.removeAll { calls >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
}

private final class OnlineAdmissionManualClock: CmxIrohRelayClock, @unchecked Sendable {
    private struct State {
        var date: Date
        var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
        var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state: State

    init(now: Date) { state = State(date: now) }

    func now() -> Date { withLock { $0.date } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = withLock { state -> (
                    immediate: Bool,
                    waiters: [CheckedContinuation<Void, Never>]
                ) in
                    guard deadline > state.date else { return (true, []) }
                    state.sleepers[id] = (deadline, continuation)
                    let waiters = state.sleepWaiters
                    state.sleepWaiters.removeAll()
                    return (false, waiters)
                }
                for waiter in result.waiters { waiter.resume() }
                if result.immediate { continuation.resume() }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func waitUntilSleeping() async {
        let sleeping = withLock { !$0.sleepers.isEmpty }
        if sleeping { return }
        await withCheckedContinuation { continuation in
            withLock { $0.sleepWaiters.append(continuation) }
        }
    }

    func sleepingDeadlines() -> [Date] {
        withLock { $0.sleepers.values.map(\.0).sorted() }
    }

    func advance(by seconds: TimeInterval) {
        let ready = withLock { state -> [(Date, CheckedContinuation<Void, any Error>)] in
            state.date = state.date.addingTimeInterval(seconds)
            let ready = state.sleepers.filter { $0.value.0 <= state.date }
            for id in ready.keys { state.sleepers[id] = nil }
            return Array(ready.values)
        }
        for sleeper in ready { sleeper.1.resume() }
    }

    private func cancel(_ id: UUID) {
        withLock { $0.sleepers.removeValue(forKey: id) }?
            .1.resume(throwing: CancellationError())
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private actor OnlineAdmissionCloseRecorder {
    private var closes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() {
        closes += 1
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func count() -> Int { closes }

    func waitUntilClosed() async {
        if closes > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct OnlineAdmissionFixture {
    let signingKey: Curve25519.Signing.PrivateKey
    let keySet: CmxIrohGrantVerificationKeySet
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let grantLifetime: Int64
    let relayURL = "https://use1-1.relay.lawrence.cmux.iroh.link/"
    let otherRelayURL = "https://euc1-1.relay.lawrence.cmux.iroh.link/"

    init(grantLifetime: Int64 = 300) throws {
        self.grantLifetime = grantLifetime
        signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0 ..< 32).map(UInt8.init))
        )
        let acceptorKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 7, count: 32)
        )
        initiator = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "ios",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: signingKey.publicKey.rawRepresentation.hex
            ),
            identityGeneration: 1
        )
        acceptor = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174003",
            deviceID: "123e4567-e89b-42d3-a456-426614174004",
            tag: "mac",
            platform: .mac,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: acceptorKey.publicKey.rawRepresentation.hex
            ),
            identityGeneration: 2
        )
        let prefix = Data([
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
            0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        keySet = CmxIrohGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [CmxIrohGrantVerificationKey(
                kid: "current",
                alg: "EdDSA",
                spkiDerBase64: (
                    prefix + signingKey.publicKey.rawRepresentation
                ).base64EncodedString()
            )]
        )
    }

    func registry(
        broker: OnlineAdmissionBroker,
        clock: (any CmxIrohRelayClock)? = nil
    ) -> CmxIrohOnlineAdmissionRegistry {
        CmxIrohOnlineAdmissionRegistry(
            broker: broker,
            keys: keySet,
            acceptor: acceptor,
            managedRelayURLs: [relayURL],
            clock: clock ?? FixedOnlineAdmissionClock(now: now)
        )
    }

    func grant(
        signer: Curve25519.Signing.PrivateKey? = nil
    ) -> String {
        let header = try! JSONSerialization.data(withJSONObject: [
            "alg": "EdDSA",
            "typ": "cmux-pair-grant+jwt",
            "kid": "current",
        ], options: [.sortedKeys])
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let payload = try! JSONSerialization.data(withJSONObject: [
            "jti": "123e4567-e89b-42d3-a456-426614174010",
            "iat": nowSeconds,
            "nbf": nowSeconds,
            "exp": nowSeconds + grantLifetime,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": peerObject(initiator),
            "acceptor": peerObject(acceptor),
        ], options: [.sortedKeys])
        let encodedHeader = header.base64URL
        let encodedPayload = payload.base64URL
        let input = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try! (signer ?? signingKey).signature(for: input)
        return "\(encodedHeader).\(encodedPayload).\(signature.base64URL)"
    }

    func offlinePair(
        initiatorLifetime: Int64 = 300,
        acceptorLifetime: Int64 = 300
    ) throws -> CmxIrohVerifiedOfflinePair {
        CmxIrohVerifiedOfflinePair(
            initiator: try attestationClaims(
                peer: initiator,
                lifetime: initiatorLifetime,
                attestationID: "123e4567-e89b-42d3-a456-426614174020"
            ),
            acceptor: try attestationClaims(
                peer: acceptor,
                lifetime: acceptorLifetime,
                attestationID: "123e4567-e89b-42d3-a456-426614174021"
            )
        )
    }

    func discovery(
        routeContractVersion: Int = 1,
        relayFleet: [String]? = nil,
        includeInitiator: Bool = true,
        duplicateInitiator: Bool = false,
        acceptorPairingEnabled: Bool = true,
        initiatorTag: String? = nil
    ) throws -> CmxIrohDiscoveryResponse {
        var bindings: [[String: Any]] = []
        if includeInitiator {
            let discoveredInitiator = CmxIrohGrantPeer(
                bindingID: initiator.bindingID,
                deviceID: initiator.deviceID,
                tag: initiatorTag ?? initiator.tag,
                platform: initiator.platform,
                endpointID: initiator.endpointID,
                identityGeneration: initiator.identityGeneration
            )
            bindings.append(bindingObject(peer: discoveredInitiator, pairingEnabled: true))
            if duplicateInitiator {
                bindings.append(bindingObject(
                    peer: CmxIrohGrantPeer(
                        bindingID: "123e4567-e89b-42d3-a456-426614174098",
                        deviceID: initiator.deviceID,
                        tag: initiator.tag,
                        platform: initiator.platform,
                        endpointID: initiator.endpointID,
                        identityGeneration: initiator.identityGeneration
                    ),
                    pairingEnabled: true,
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174099"
                ))
            }
        }
        bindings.append(bindingObject(
            peer: acceptor,
            pairingEnabled: acceptorPairingEnabled
        ))
        let response: [String: Any] = [
            "route_contract_version": routeContractVersion,
            "bindings": bindings,
            "relay_fleet": relayFleet ?? [relayURL],
            "lan_rendezvous": [
                "generation": 1,
                "key": Data(repeating: 3, count: 32).base64URL,
            ],
            "grant_verification_keys": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(keySet)
            ),
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: response)
        )
    }

    private func bindingObject(
        peer: CmxIrohGrantPeer,
        pairingEnabled: Bool,
        appInstanceID: String = "123e4567-e89b-42d3-a456-426614174005"
    ) -> [String: Any] {
        [
            "binding_id": peer.bindingID,
            "device_id": peer.deviceID,
            "app_instance_id": appInstanceID,
            "tag": peer.tag,
            "platform": peer.platform.rawValue,
            "display_name": NSNull(),
            "endpoint_id": peer.endpointID.endpointID,
            "identity_generation": peer.identityGeneration,
            "pairing_enabled": pairingEnabled,
            "capabilities": ["multistream-v1"],
            "path_hints": [],
            "last_seen_at": "2027-01-15T08:00:00Z",
        ]
    }

    private func peerObject(_ peer: CmxIrohGrantPeer) -> [String: Any] {
        [
            "bindingId": peer.bindingID,
            "deviceId": peer.deviceID,
            "tag": peer.tag,
            "platform": peer.platform.rawValue,
            "endpointId": peer.endpointID.endpointID,
            "identityGeneration": peer.identityGeneration,
        ]
    }

    private func attestationClaims(
        peer: CmxIrohGrantPeer,
        lifetime: Int64,
        attestationID: String
    ) throws -> CmxIrohEndpointAttestationClaims {
        let seconds = Int64(now.timeIntervalSince1970)
        return try JSONDecoder().decode(
            CmxIrohEndpointAttestationClaims.self,
            from: JSONSerialization.data(withJSONObject: [
                "version": 1,
                "jti": attestationID,
                "sub": Data(repeating: 7, count: 32).base64URL,
                "bindingId": peer.bindingID,
                "deviceId": peer.deviceID,
                "endpointId": peer.endpointID.endpointID,
                "identityGeneration": peer.identityGeneration,
                "platform": peer.platform.rawValue,
                "iat": seconds,
                "nbf": seconds,
                "exp": seconds + lifetime,
                "alpn": "cmux/mobile/1",
                "scope": "cmux.offline-pair.same-account",
            ])
        )
    }
}

private struct FixedOnlineAdmissionClock: CmxIrohRelayClock {
    let current: Date
    init(now: Date) { current = now }
    func now() -> Date { current }
    func sleep(until _: Date) async throws {
        try await Task<Never, Never>.sleep(for: .seconds(24 * 60 * 60))
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
