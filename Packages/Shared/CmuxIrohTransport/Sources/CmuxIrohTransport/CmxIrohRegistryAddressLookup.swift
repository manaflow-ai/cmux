import CMUXMobileCore
public import Foundation
public import IrohLib
import os

/// Re-exposes the iroh-ffi foreign trait so app layers can pass a lookup
/// through factory seams without importing IrohLib themselves.
public typealias CmxIrohAddressLookupServing = AddressLookupService

/// Broker access needed by the registry address lookup.
///
/// The fetch side returns every signed endpoint record the broker currently
/// serves for this account (opaque pkarr signed-packet blobs). The publish
/// side uploads this endpoint's own signed record. Both ride the existing
/// authenticated trust-broker transport; no credential crosses the FFI.
public protocol CmxIrohEndpointRecordBroker: Sendable {
    /// Fetches every stored endpoint record for the account.
    func fetchEndpointRecords() async throws -> [Data]

    /// Uploads this endpoint's own signed record.
    func publishEndpointRecord(_ record: Data) async throws
}

/// Diagnostic mirror of the lookup's install state and last outcomes,
/// printed by the `iroh-diag` socket verb.
public struct CmxIrohAddressLookupDiagnostics: Equatable, Sendable {
    /// Where a resolve answer came from, or why it produced nothing.
    public enum ResolveSource: String, Equatable, Sendable {
        case recordCache = "record cache"
        case persistedCache = "persisted cache"
        case brokerFetch = "broker fetch"
        case noResults = "no results"
        case fetchCoolingDown = "fetch cooling down"
        case fetchFailedTransient = "fetch failed (transient)"
        case fetchFailedTrust = "fetch failed (non-transient)"
    }

    /// The terminal state of one publish callback.
    public enum PublishResult: String, Equatable, Sendable {
        case published
        case rejectedRecord = "rejected record"
        case uploadFailed = "upload failed"
    }

    /// One completed resolve, keyed by a shortened endpoint id.
    public struct ResolveOutcome: Equatable, Sendable {
        public let endpointIDPrefix: String
        public let source: ResolveSource
        public let recordCount: Int
        public let at: Date
    }

    /// One completed publish callback.
    public struct PublishOutcome: Equatable, Sendable {
        public let result: PublishResult
        public let recordByteCount: Int
        public let at: Date
    }

    /// When the lookup instance was created.
    public let installedAt: Date
    /// Completed resolve callbacks.
    public private(set) var resolveCount: Int
    /// Completed publish callbacks.
    public private(set) var publishCount: Int
    /// The most recent resolve outcome.
    public private(set) var lastResolve: ResolveOutcome?
    /// The most recent publish outcome.
    public private(set) var lastPublish: PublishOutcome?

    init(installedAt: Date) {
        self.installedAt = installedAt
        resolveCount = 0
        publishCount = 0
    }

    mutating func recordResolve(_ outcome: ResolveOutcome) {
        resolveCount += 1
        lastResolve = outcome
    }

    mutating func recordPublish(_ outcome: PublishOutcome) {
        publishCount += 1
        lastPublish = outcome
    }
}

/// The registry-backed implementation of the iroh `AddressLookupService`
/// foreign trait (manaflow-ai/iroh-ffi `v1.0.2-cmux.9` surface).
///
/// Resolve answers from, in order: the in-memory record cache (zero network),
/// an injected persisted-record source (offline/binding caches), then at most
/// one bounded broker fetch. The fetch is single-flight (concurrent resolves
/// join it) and cools down after failures using the codified trust-broker
/// transient taxonomy: transient failures back off on the foreground client
/// schedule, non-transient (trust) failures fail closed on the slower host
/// schedule. Records are accepted only through
/// ``CmxIrohEndpointRecordPolicy`` (Rust re-verifies signatures afterwards).
///
/// Publish verifies the endpoint's own record, stores it in the record cache,
/// and uploads it to the trust broker as an opaque blob.
public final class CmxIrohRegistryAddressLookup: AddressLookupService {
    /// Fetch-side coordination owned by one actor: single-flight join,
    /// failure counting, and the taxonomy-gated cooldown clock.
    private actor FetchState {
        private let broker: any CmxIrohEndpointRecordBroker
        private let transientSchedule: CmxIrohRetrySchedule
        private let nonTransientSchedule: CmxIrohRetrySchedule
        private let jitter: @Sendable () -> Double
        private var inFlight: Task<[Data], any Error>?
        private var failureCount = 0
        private var nextFetchAllowedAt = Date.distantPast

        init(
            broker: any CmxIrohEndpointRecordBroker,
            transientSchedule: CmxIrohRetrySchedule,
            nonTransientSchedule: CmxIrohRetrySchedule,
            jitter: @escaping @Sendable () -> Double
        ) {
            self.broker = broker
            self.transientSchedule = transientSchedule
            self.nonTransientSchedule = nonTransientSchedule
            self.jitter = jitter
        }

        enum FetchDisposition {
            case fetched([Data])
            case coolingDown(until: Date)
            case failed(transient: Bool, error: any Error)
        }

        /// Publishes through the same broker the fetch side uses, so tests
        /// observing broker traffic see a single serialized client.
        func publish(record: Data) async throws {
            try await broker.publishEndpointRecord(record)
        }

        func fetchOnce(now: Date) async -> FetchDisposition {
            if let inFlight {
                do {
                    return .fetched(try await inFlight.value)
                } catch {
                    // The joiner reports the shared failure; the owner already
                    // advanced the cooldown clock.
                    return .failed(
                        transient: CmxIrohTrustBrokerClientError
                            .preservesVerifiedStateDuringRefresh(error),
                        error: error
                    )
                }
            }
            guard now >= nextFetchAllowedAt else {
                return .coolingDown(until: nextFetchAllowedAt)
            }
            let broker = broker
            let task = Task { try await broker.fetchEndpointRecords() }
            inFlight = task
            defer { inFlight = nil }
            do {
                let records = try await task.value
                failureCount = 0
                nextFetchAllowedAt = .distantPast
                return .fetched(records)
            } catch {
                let transient = CmxIrohTrustBrokerClientError
                    .preservesVerifiedStateDuringRefresh(error)
                let schedule = transient ? transientSchedule : nonTransientSchedule
                let delay = schedule.delay(
                    failureCount: failureCount,
                    retryAfterSeconds:
                        (error as? any CmxRetryAfterProviding)?.retryAfterSeconds,
                    jitterUnitInterval: jitter()
                )
                failureCount += 1
                nextFetchAllowedAt = now.addingTimeInterval(delay)
                return .failed(transient: transient, error: error)
            }
        }
    }

    private let recordCache: CmxIrohEndpointRecordCache
    private let persistedRecords: @Sendable (String) async -> [Data]
    private let allowedRelayURLs: @Sendable () async -> Set<String>
    private let fetchState: FetchState
    private let dateProvider: @Sendable () -> Date
    private let diagnostics: OSAllocatedUnfairLock<CmxIrohAddressLookupDiagnostics>

    /// Creates the lookup service.
    ///
    /// - Parameters:
    ///   - broker: Authenticated record fetch/publish transport.
    ///   - allowedRelayURLs: The exact relay origins currently permitted
    ///     (managed catalog, custom profile, or debug override), read per call
    ///     so a policy refresh applies immediately.
    ///   - persistedRecords: Candidate record blobs for an endpoint id from
    ///     persisted caches, consulted before any network fetch.
    ///   - recordCache: The in-memory record store.
    ///   - transientFetchSchedule: Backoff for transient fetch failures.
    ///   - nonTransientFetchSchedule: Backoff for trust (non-transient)
    ///     fetch failures; fail-closed floor.
    ///   - jitter: Deterministic-in-tests jitter source in `0...1`.
    ///   - dateProvider: Injectable clock.
    public init(
        broker: any CmxIrohEndpointRecordBroker,
        allowedRelayURLs: @escaping @Sendable () async -> Set<String>,
        persistedRecords: @escaping @Sendable (String) async -> [Data] = { _ in [] },
        recordCache: CmxIrohEndpointRecordCache = CmxIrohEndpointRecordCache(),
        transientFetchSchedule: CmxIrohRetrySchedule = .foregroundClient,
        nonTransientFetchSchedule: CmxIrohRetrySchedule = CmxIrohRetrySchedule(
            initialDelay: 300,
            maximumDelay: 3_600
        ),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recordCache = recordCache
        self.persistedRecords = persistedRecords
        self.allowedRelayURLs = allowedRelayURLs
        fetchState = FetchState(
            broker: broker,
            transientSchedule: transientFetchSchedule,
            nonTransientSchedule: nonTransientFetchSchedule,
            jitter: jitter
        )
        self.dateProvider = dateProvider
        diagnostics = OSAllocatedUnfairLock(
            initialState: CmxIrohAddressLookupDiagnostics(
                installedAt: dateProvider()
            )
        )
    }

    /// A thread-safe snapshot for the `iroh-diag` socket verb. Never hops to
    /// the main actor, so it stays readable while the app is wedged.
    public func diagnosticsSnapshot() -> CmxIrohAddressLookupDiagnostics {
        diagnostics.withLock { $0 }
    }

    // MARK: - AddressLookupService

    public func resolve(endpointId: EndpointId) async throws -> [Data] {
        let key = CmxIrohEndpointRecordPolicy.canonicalEndpointID(endpointId)
        let prefix = String(key.prefix(10))
        let allowed = await allowedRelayURLs()

        if let entry = await recordCache.entry(for: key),
           let verified = CmxIrohEndpointRecordPolicy.acceptableRecord(
               blob: entry.blob,
               endpointID: key,
               allowedRelayURLs: allowed,
               now: dateProvider()
           ) {
            recordResolve(prefix: prefix, source: .recordCache, count: 1)
            return [verified.blob]
        }

        for blob in await persistedRecords(key) {
            guard let verified = CmxIrohEndpointRecordPolicy.acceptableRecord(
                blob: blob,
                endpointID: key,
                allowedRelayURLs: allowed,
                now: dateProvider()
            ) else { continue }
            await recordCache.store(
                blob: verified.blob,
                endpointID: verified.endpointID,
                signedAt: verified.signedAt,
                now: dateProvider()
            )
            recordResolve(prefix: prefix, source: .persistedCache, count: 1)
            return [verified.blob]
        }

        switch await fetchState.fetchOnce(now: dateProvider()) {
        case let .fetched(blobs):
            var accepted: [Data] = []
            for blob in blobs {
                // Cache every well-formed fetched record (policy re-applies at
                // read), answer with the ones for the requested endpoint.
                guard let verified = CmxIrohEndpointRecordPolicy.acceptableRecord(
                    blob: blob,
                    endpointID: nil,
                    allowedRelayURLs: allowed,
                    now: dateProvider()
                ) else { continue }
                await recordCache.store(
                    blob: verified.blob,
                    endpointID: verified.endpointID,
                    signedAt: verified.signedAt,
                    now: dateProvider()
                )
                if verified.endpointID == key {
                    accepted.append(verified.blob)
                }
            }
            recordResolve(
                prefix: prefix,
                source: accepted.isEmpty ? .noResults : .brokerFetch,
                count: accepted.count
            )
            return accepted
        case .coolingDown:
            recordResolve(prefix: prefix, source: .fetchCoolingDown, count: 0)
            return []
        case let .failed(transient, _):
            recordResolve(
                prefix: prefix,
                source: transient ? .fetchFailedTransient : .fetchFailedTrust,
                count: 0
            )
            throw CallbackError.Error
        }
    }

    public func publish(record: Data) async throws {
        let allowed = await allowedRelayURLs()
        guard let verified = CmxIrohEndpointRecordPolicy.acceptableRecord(
            blob: record,
            endpointID: nil,
            allowedRelayURLs: allowed,
            now: dateProvider()
        ) else {
            recordPublish(result: .rejectedRecord, byteCount: record.count)
            throw CallbackError.Error
        }
        await recordCache.store(
            blob: verified.blob,
            endpointID: verified.endpointID,
            signedAt: verified.signedAt,
            now: dateProvider()
        )
        do {
            try await fetchState.publish(record: record)
            recordPublish(result: .published, byteCount: record.count)
        } catch {
            recordPublish(result: .uploadFailed, byteCount: record.count)
            throw CallbackError.Error
        }
    }

    // MARK: - Private

    private func recordResolve(
        prefix: String,
        source: CmxIrohAddressLookupDiagnostics.ResolveSource,
        count: Int
    ) {
        let outcome = CmxIrohAddressLookupDiagnostics.ResolveOutcome(
            endpointIDPrefix: prefix,
            source: source,
            recordCount: count,
            at: dateProvider()
        )
        diagnostics.withLock { $0.recordResolve(outcome) }
    }

    private func recordPublish(
        result: CmxIrohAddressLookupDiagnostics.PublishResult,
        byteCount: Int
    ) {
        let outcome = CmxIrohAddressLookupDiagnostics.PublishOutcome(
            result: result,
            recordByteCount: byteCount,
            at: dateProvider()
        )
        diagnostics.withLock { $0.recordPublish(outcome) }
    }
}
