import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh client offline policy cache")
struct CmxIrohClientOfflinePolicyCacheTests {
    @Test("verified target policy round-trips with device-only protection")
    func roundTripsVerifiedPolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: expectation,
            now: fixture.now
        )

        let recreated = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let loaded = try await recreated.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now
        )
        #expect(loaded?.localBinding == discovery.bindings[0])
        #expect(loaded?.targetBinding == discovery.bindings[1])
        #expect(loaded?.pairGrant == grant)
        #expect(loaded?.lanRendezvous == discovery.lanRendezvous)
        #expect(await store.observedAccessibilities() == [.afterFirstUnlockThisDeviceOnly])
    }

    @Test("save rejects grants that do not bind the exact target")
    func saveRejectsSubstitutedTarget() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let substituted = try fixture.discovery(
            targetHints: [],
            targetDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)

        await #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try await cache.save(
                localBinding: discovery.bindings[0],
                targetBinding: substituted.bindings[1],
                discovery: substituted,
                pairGrant: fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
                for: fixture.offlineExpectation(),
                now: fixture.now
            )
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("load re-verifies expiry and deletes stale authority")
    func loadDeletesExpiredGrant() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let cacheStore = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: cacheStore)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 60
            ),
            for: expectation,
            now: fixture.now
        )

        let loaded = try await cache.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now.addingTimeInterval(61)
        )

        #expect(loaded == nil)
        #expect(await cacheStore.recordCount() == 0)
    }

    @Test("account and local identity changes wipe the active cache")
    func changedScopeDeletesPolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )

        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(accountID: "account-b"),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("unknown and substituted Mac tuples never receive cached authority")
    func requestMustMatchKnownTargetTuple() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: expectation,
            now: fixture.now
        )

        let unknown = try fixture.request(
            hints: [],
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        #expect(try await cache.load(
            for: unknown,
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 1)
    }

    @Test("corrupt records and changed relay fleets are deleted")
    func corruptAndWrongFleetDeletePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let account = try #require(await store.lastDeletedOrWrittenAccount())
        await store.seed(Data("not-json".utf8), account: account)
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(
                managedRelayURLs: ["https://other.example.com/"]
            ),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("changed local identity and confirmed target revocation delete authority")
    func localIdentityAndConfirmedRevocationDeletePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 3_600
        )
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let changedLocal = try CmxIrohLocalBindingExpectation(
            deviceID: fixture.initiator.deviceID,
            appInstanceID: discovery.bindings[0].appInstanceID,
            tag: fixture.initiator.tag,
            platform: .ios,
            endpointID: fixture.initiator.endpointID,
            identityGeneration: fixture.initiator.identityGeneration + 1,
            pairingEnabled: false,
            capabilities: discovery.bindings[0].capabilities
        )
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(localExpectation: changedLocal),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let revoked = try fixture.discovery(targetHints: [], includeTarget: false)
        #expect(try await cache.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: fixture.offlineExpectation(),
            confirmedDiscovery: revoked,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("deactivate invalidates a suspended save before it can repopulate policy")
    func deactivateInvalidatesSuspendedSave() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = SuspendingSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        await store.suspendNextRead()
        let saveTask = Task {
            try await cache.save(
                localBinding: discovery.bindings[0],
                targetBinding: discovery.bindings[1],
                discovery: discovery,
                pairGrant: fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 3_600
                ),
                for: fixture.offlineExpectation(),
                now: fixture.now
            )
        }
        await store.waitUntilReadIsSuspended()

        try await cache.deactivate()
        #expect(await store.recordCount() == 0)
        await store.resumeSuspendedRead()

        await #expect(throws: CancellationError.self) {
            try await saveTask.value
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("deactivate invalidates a suspended bootstrap load after deleting policy")
    func deactivateInvalidatesSuspendedBootstrapLoad() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = SuspendingSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: expectation,
            now: fixture.now
        )
        await store.suspendNextRead()
        let loadTask = Task {
            try await cache.loadBootstrap(
                for: expectation,
                confirmedLocalBinding: discovery.bindings[0],
                now: fixture.now
            )
        }
        await store.waitUntilReadIsSuspended()

        try await cache.deactivate()
        #expect(await store.recordCount() == 0)
        await store.resumeSuspendedRead()

        await #expect(throws: CancellationError.self) {
            try await loadTask.value
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("deactivate drains a suspended write before its final delete")
    func deactivateDrainsSuspendedWriteBeforeFinalDelete() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = SuspendingSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        await store.suspendNextWrite()
        let saveTask = Task {
            try await cache.save(
                localBinding: discovery.bindings[0],
                targetBinding: discovery.bindings[1],
                discovery: discovery,
                pairGrant: fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 3_600
                ),
                for: expectation,
                now: fixture.now
            )
        }
        await store.waitUntilWriteIsSuspended()
        #expect(await store.recordCount() == 0)

        let deactivateTask = Task {
            try await cache.deactivate()
        }
        let probeRequest = CmxByteTransportRequest(
            route: try fixture.route(hints: []),
            expectedPeerDeviceID: fixture.acceptor.deviceID,
            authorizationMode: .stackBearer
        )
        var observedDeactivation = false
        for _ in 0 ..< 1_024 where !observedDeactivation {
            do {
                let result = try await cache.load(
                    for: probeRequest,
                    localBinding: discovery.bindings[0],
                    expectation: expectation,
                    confirmedDiscovery: nil,
                    now: fixture.now
                )
                #expect(result == nil)
                await Task.yield()
            } catch is CancellationError {
                observedDeactivation = true
            }
        }
        #expect(observedDeactivation)
        #expect(await store.deleteAllCallCount() == 0)

        await store.resumeSuspendedWrite()
        await #expect(throws: CancellationError.self) {
            try await saveTask.value
        }
        try await deactivateTask.value

        #expect(await store.deleteAllCallCount() == 1)
        #expect(await store.recordCount() == 0)
    }
}

private actor SuspendingSecureCredentialStore: CmxIrohSecureCredentialStoring {
    private var records: [String: Data] = [:]
    private var shouldSuspendNextRead = false
    private var suspendedRead: CheckedContinuation<Void, Never>?
    private var readSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextWrite = false
    private var suspendedWrite: CheckedContinuation<Void, Never>?
    private var writeSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var deleteAllCalls = 0

    func read(account: String) async -> Data? {
        let captured = records[account]
        guard shouldSuspendNextRead else { return captured }
        shouldSuspendNextRead = false
        await withCheckedContinuation { continuation in
            suspendedRead = continuation
            let waiters = readSuspensionWaiters
            readSuspensionWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
        return captured
    }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) async {
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            await withCheckedContinuation { continuation in
                suspendedWrite = continuation
                let waiters = writeSuspensionWaiters
                writeSuspensionWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        records[account] = data
    }

    func delete(account: String) {
        records.removeValue(forKey: account)
    }

    func deleteAll() {
        records.removeAll(keepingCapacity: false)
        deleteAllCalls += 1
    }

    func suspendNextRead() {
        shouldSuspendNextRead = true
    }

    func waitUntilReadIsSuspended() async {
        guard suspendedRead == nil else { return }
        await withCheckedContinuation { continuation in
            readSuspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedRead() {
        let continuation = suspendedRead
        suspendedRead = nil
        continuation?.resume()
    }

    func suspendNextWrite() {
        shouldSuspendNextWrite = true
    }

    func waitUntilWriteIsSuspended() async {
        guard suspendedWrite == nil else { return }
        await withCheckedContinuation { continuation in
            writeSuspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedWrite() {
        let continuation = suspendedWrite
        suspendedWrite = nil
        continuation?.resume()
    }

    func deleteAllCallCount() -> Int {
        deleteAllCalls
    }

    func recordCount() -> Int {
        records.count
    }
}
