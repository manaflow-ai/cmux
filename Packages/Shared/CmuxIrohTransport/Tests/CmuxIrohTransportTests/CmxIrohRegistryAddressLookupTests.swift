import Foundation
import IrohLib
import Testing
@testable import CmuxIrohTransport

/// Records broker traffic and injects per-call fetch/publish outcomes.
private actor TestEndpointRecordBroker: CmxIrohEndpointRecordBroker {
    private(set) var fetchCount = 0
    private(set) var publishedRecords: [Data] = []
    private var fetchRecords: [Data] = []
    private var fetchError: (any Error)?
    private var publishError: (any Error)?

    func setFetchRecords(_ records: [Data]) { fetchRecords = records }
    func setFetchError(_ error: (any Error)?) { fetchError = error }
    func setPublishError(_ error: (any Error)?) { publishError = error }

    func fetchEndpointRecords() async throws -> [Data] {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return fetchRecords
    }

    func publishEndpointRecord(_ record: Data) async throws {
        if let publishError { throw publishError }
        publishedRecords.append(record)
    }
}

private struct RecordFixture {
    let secretKey: SecretKey
    let endpointID: EndpointId
    let endpointIDHex: String
    let record: Data
    let relayURL: String

    init(relayURL: String = "https://relay.example.com/") throws {
        secretKey = SecretKey.generate()
        endpointID = secretKey.public()
        endpointIDHex = CmxIrohEndpointRecordPolicy.canonicalEndpointID(endpointID)
        self.relayURL = relayURL
        record = try signEndpointRecord(
            secretKey: secretKey,
            relayUrls: [relayURL],
            directAddrs: ["192.168.10.20:4433"],
            ttlSeconds: 30
        )
    }
}

@Suite
struct CmxIrohRegistryAddressLookupTests {
    private static let allowedRelays: Set<String> = ["https://relay.example.com/"]

    private func makeLookup(
        broker: TestEndpointRecordBroker,
        cache: CmxIrohEndpointRecordCache = CmxIrohEndpointRecordCache(),
        allowedRelayURLs: Set<String> = allowedRelays,
        persistedRecords: @escaping @Sendable (String) async -> [Data] = { _ in [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CmxIrohRegistryAddressLookup {
        CmxIrohRegistryAddressLookup(
            broker: broker,
            allowedRelayURLs: { allowedRelayURLs },
            persistedRecords: persistedRecords,
            recordCache: cache,
            jitter: { 0 },
            dateProvider: now
        )
    }

    @Test("cached record resolves with zero network traffic")
    func cachedRecordResolvesWithZeroNetwork() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        let cache = CmxIrohEndpointRecordCache()
        await cache.store(
            blob: fixture.record,
            endpointID: fixture.endpointIDHex,
            signedAt: Date()
        )
        let lookup = makeLookup(broker: broker, cache: cache)

        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records == [fixture.record])
        #expect(await broker.fetchCount == 0)
        let diagnostics = lookup.diagnosticsSnapshot()
        #expect(diagnostics.lastResolve?.source == .recordCache)
        #expect(diagnostics.resolveCount == 1)
    }

    @Test("persisted cache answers before any broker fetch")
    func persistedCacheAnswersBeforeBrokerFetch() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        let record = fixture.record
        let lookup = makeLookup(
            broker: broker,
            persistedRecords: { _ in [record] }
        )

        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records == [fixture.record])
        #expect(await broker.fetchCount == 0)
        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .persistedCache)
    }

    @Test("cache miss fetches once, then serves later resolves from cache")
    func brokerFetchHappensOnceThenCaches() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchRecords([fixture.record])
        let lookup = makeLookup(broker: broker)

        let first = try await lookup.resolve(endpointId: fixture.endpointID)
        let second = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(first == [fixture.record])
        #expect(second == [fixture.record])
        #expect(await broker.fetchCount == 1)
        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .recordCache)
    }

    @Test("transient broker failure throws, then cools down without refetching")
    func transientFailureCoolsDown() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchError(CmxIrohTrustBrokerClientError.connectivity)
        let lookup = makeLookup(broker: broker)

        await #expect(throws: CallbackError.self) {
            _ = try await lookup.resolve(endpointId: fixture.endpointID)
        }
        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .fetchFailedTransient)

        // The cooldown window rejects an immediate second fetch: the resolve
        // returns no results instead of dialing the broker again.
        await broker.setFetchError(nil)
        await broker.setFetchRecords([fixture.record])
        let cooled = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(cooled.isEmpty)
        #expect(await broker.fetchCount == 1)
        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .fetchCoolingDown)
    }

    @Test("non-transient broker failure fails closed with the slow schedule")
    func nonTransientFailureFailsClosed() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchError(CmxIrohTrustBrokerClientError.invalidResponse)
        let lookup = makeLookup(broker: broker)

        await #expect(throws: CallbackError.self) {
            _ = try await lookup.resolve(endpointId: fixture.endpointID)
        }

        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .fetchFailedTrust)
        #expect(await broker.fetchCount == 1)
    }

    @Test("cooldown expiry allows exactly one new fetch")
    func cooldownExpiryAllowsNewFetch() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchError(CmxIrohTrustBrokerClientError.connectivity)
        let clock = TestClock()
        let lookup = makeLookup(broker: broker, now: { clock.now() })

        await #expect(throws: CallbackError.self) {
            _ = try await lookup.resolve(endpointId: fixture.endpointID)
        }

        // .foregroundClient first delay with zero jitter is bounded by its
        // floor; advancing well past the cap re-arms the fetch.
        clock.advance(by: 120)
        await broker.setFetchError(nil)
        await broker.setFetchRecords([fixture.record])
        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records == [fixture.record])
        #expect(await broker.fetchCount == 2)
    }

    @Test("records naming relays outside the allowlist are dropped whole")
    func relayAllowlistFiltersRecords() async throws {
        let fixture = try RecordFixture(relayURL: "https://relay.evil.example/")
        let broker = TestEndpointRecordBroker()
        await broker.setFetchRecords([fixture.record])
        let lookup = makeLookup(broker: broker)

        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records.isEmpty)
        #expect(lookup.diagnosticsSnapshot().lastResolve?.source == .noResults)
    }

    @Test("allowlist matching tolerates one trailing slash")
    func relayAllowlistToleratesTrailingSlash() async throws {
        // Records canonicalize relay URLs with a trailing slash; the policy
        // set may store the origin without one.
        let fixture = try RecordFixture(relayURL: "https://relay.example.com/")
        let broker = TestEndpointRecordBroker()
        await broker.setFetchRecords([fixture.record])
        let lookup = makeLookup(
            broker: broker,
            allowedRelayURLs: ["https://relay.example.com"]
        )

        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records == [fixture.record])
    }

    @Test("stale records are rejected by the freshness window")
    func staleRecordsAreRejected() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchRecords([fixture.record])
        let farFuture = Date().addingTimeInterval(
            CmxIrohEndpointRecordPolicy.maximumRecordAge * 2
        )
        let lookup = makeLookup(broker: broker, now: { farFuture })

        let records = try await lookup.resolve(endpointId: fixture.endpointID)

        #expect(records.isEmpty)
    }

    @Test("resolve rejects a valid record signed by a different endpoint")
    func resolveRejectsWrongEndpointRecord() async throws {
        let requested = try RecordFixture()
        let other = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setFetchRecords([other.record])
        let lookup = makeLookup(broker: broker)

        let records = try await lookup.resolve(endpointId: requested.endpointID)

        // The other endpoint's record is cached for its own id but never
        // answers the requested endpoint.
        #expect(records.isEmpty)
        let cached = try await lookup.resolve(endpointId: other.endpointID)
        #expect(cached == [other.record])
        #expect(await broker.fetchCount == 1)
    }

    @Test("publish uploads the record and primes the resolve cache")
    func publishUploadsAndCaches() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        let lookup = makeLookup(broker: broker)

        try await lookup.publish(record: fixture.record)

        #expect(await broker.publishedRecords == [fixture.record])
        let diagnostics = lookup.diagnosticsSnapshot()
        #expect(diagnostics.lastPublish?.result == .published)
        #expect(diagnostics.publishCount == 1)

        // The published record now resolves with zero further broker calls.
        let records = try await lookup.resolve(endpointId: fixture.endpointID)
        #expect(records == [fixture.record])
        #expect(await broker.fetchCount == 0)
    }

    @Test("publish rejects a malformed record without posting")
    func publishRejectsMalformedRecord() async throws {
        let broker = TestEndpointRecordBroker()
        let lookup = makeLookup(broker: broker)

        await #expect(throws: CallbackError.self) {
            try await lookup.publish(record: Data([0x00, 0x01, 0x02]))
        }

        #expect(await broker.publishedRecords.isEmpty)
        #expect(lookup.diagnosticsSnapshot().lastPublish?.result == .rejectedRecord)
    }

    @Test("publish upload failure surfaces and records the outcome")
    func publishUploadFailureSurfaces() async throws {
        let fixture = try RecordFixture()
        let broker = TestEndpointRecordBroker()
        await broker.setPublishError(CmxIrohTrustBrokerClientError.connectivity)
        let lookup = makeLookup(broker: broker)

        await #expect(throws: CallbackError.self) {
            try await lookup.publish(record: fixture.record)
        }

        #expect(lookup.diagnosticsSnapshot().lastPublish?.result == .uploadFailed)
    }

    @Test("sign/parse round trip verifies and a tampered record fails")
    func recordRoundTripAndTamperDetection() throws {
        let fixture = try RecordFixture()

        let summary = try parseEndpointRecord(bytes: fixture.record)
        #expect(
            CmxIrohEndpointRecordPolicy.canonicalEndpointID(summary.endpointId)
                == fixture.endpointIDHex
        )
        #expect(summary.relayUrls == [fixture.relayURL])

        var tampered = fixture.record
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try parseEndpointRecord(bytes: tampered)
        }
    }
}

/// Deterministic manual clock for cooldown tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
