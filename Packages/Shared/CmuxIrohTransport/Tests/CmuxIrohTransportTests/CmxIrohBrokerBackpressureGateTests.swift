import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohBrokerBackpressureGateTests {
    private let start = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func persistedDeadlineSurvivesGateRecreation() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let original = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start }
        )
        await recordRateLimit(
            gate: original,
            accountID: "account-a",
            operation: .discovery,
            seconds: 600
        )

        let recreated = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start.addingTimeInterval(1) }
        )
        #expect(await recreated.remainingSeconds(
            accountID: "account-a",
            operation: .discovery
        ) == 599)
        do {
            try await recreated.preflight(
                accountID: "account-a",
                operation: .discovery
            )
            Issue.record("Expected the persisted floor to reject discovery")
        } catch {
            #expect((error as? CmxIrohBrokerCooldownError)?.retryAfterSeconds == 599)
        }
    }

    @Test
    func malformedExpiredAndFutureRecordsArePurged() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)

        store.set("not-base64", forKey: CmxIrohBrokerBackpressureGate.persistenceKey)
        _ = CmxIrohBrokerBackpressureGate(store: store, now: { start })
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) == nil)

        let gate = CmxIrohBrokerBackpressureGate(store: store, now: { start })
        await recordRateLimit(
            gate: gate,
            accountID: "account-a",
            operation: .discovery,
            seconds: 1
        )
        let expired = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start.addingTimeInterval(2) }
        )
        #expect(await expired.remainingSeconds(
            accountID: "account-a",
            operation: .discovery
        ) == nil)
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) == nil)

        let future = start.addingTimeInterval(1)
        let futureRecord: [String: Any] = [
            "version": 1,
            "floors": [[
                "key": [
                    "accountScope": String(repeating: "a", count: 64),
                    "operation": CmxIrohBrokerOperation.discovery.rawValue,
                ],
                "recordedAt": future.timeIntervalSinceReferenceDate,
                "retryAt": future.addingTimeInterval(600).timeIntervalSinceReferenceDate,
            ]],
        ]
        store.set(
            try JSONSerialization.data(withJSONObject: futureRecord).base64EncodedString(),
            forKey: CmxIrohBrokerBackpressureGate.persistenceKey
        )
        _ = CmxIrohBrokerBackpressureGate(store: store, now: { start })
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) == nil)
    }

    @Test
    func inMemoryFloorIsPurgedWhenClockMovesBehindRecordedAt() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let clock = BackpressureGateClock(start)
        let gate = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { clock.now() }
        )
        await recordRateLimit(
            gate: gate,
            accountID: "account-a",
            operation: .discovery,
            seconds: 600
        )
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) != nil)

        clock.set(start.addingTimeInterval(-1))

        #expect(await gate.remainingSeconds(
            accountID: "account-a",
            operation: .discovery
        ) == nil)
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) == nil)
    }

    @Test
    func floorsAreIsolatedByAccountAndOperation() async throws {
        let gate = CmxIrohBrokerBackpressureGate(now: { start })
        await recordRateLimit(
            gate: gate,
            accountID: "account-a",
            operation: .discovery,
            seconds: 600
        )

        #expect(await gate.remainingSeconds(
            accountID: "account-a",
            operation: .discovery
        ) == 600)
        #expect(await gate.remainingSeconds(
            accountID: "account-b",
            operation: .discovery
        ) == nil)
        #expect(await gate.remainingSeconds(
            accountID: "account-a",
            operation: .revocation
        ) == nil)
        try await gate.preflight(accountID: "account-b", operation: .discovery)
        try await gate.preflight(accountID: "account-a", operation: .revocation)
    }

    @Test
    func concurrentSameOperationStopsAfterFirstRateLimit() async throws {
        let gate = CmxIrohBrokerBackpressureGate(now: { start })
        let probe = BackpressureGateProbe()
        let first = Task {
            do {
                _ = try await gate.perform(
                    accountID: "account-a",
                    operation: .discovery
                ) {
                    try await probe.request()
                }
                return false
            } catch {
                return true
            }
        }
        await probe.waitForRequestCount(1)
        #expect(await probe.requestCount() == 1)

        let second = Task {
            do {
                _ = try await gate.perform(
                    accountID: "account-a",
                    operation: .discovery
                ) {
                    try await probe.request()
                }
                return false
            } catch {
                return true
            }
        }
        await Task.yield()
        #expect(await probe.requestCount() == 1)
        await probe.releaseFirstRequest()

        #expect(await first.value)
        #expect(await second.value)
        #expect(await probe.requestCount() == 1)
    }

    @Test
    func persistenceNeverContainsRawAccountID() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = "user_private_account_identifier"
        let store = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let gate = CmxIrohBrokerBackpressureGate(store: store, now: { start })
        await recordRateLimit(
            gate: gate,
            accountID: accountID,
            operation: .relayCredential,
            seconds: 600
        )

        let encoded = try #require(
            store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey)
        )
        let persisted = try #require(Data(base64Encoded: encoded))
        #expect(!String(decoding: persisted, as: UTF8.self).contains(accountID))
    }

    @Test
    func persistenceOverflowConservativelyProtectsEveryActiveFloor() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let original = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start }
        )
        let accounts = (0 ... 64).map { "account-\($0)" }
        for accountID in accounts {
            await recordRateLimit(
                gate: original,
                accountID: accountID,
                operation: .discovery,
                seconds: 600
            )
        }

        let recreated = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start.addingTimeInterval(1) }
        )
        var protectedAccountCount = 0
        for accountID in accounts {
            if await recreated.remainingSeconds(
                accountID: accountID,
                operation: .discovery
            ) == 599 {
                protectedAccountCount += 1
            }
        }

        #expect(protectedAccountCount == accounts.count)
        #expect(await recreated.remainingSeconds(
            accountID: "account-not-in-record",
            operation: .registration
        ) == 599)

        let expired = CmxIrohBrokerBackpressureGate(
            store: store,
            now: { start.addingTimeInterval(601) }
        )
        #expect(await expired.remainingSeconds(
            accountID: "account-not-in-record",
            operation: .registration
        ) == nil)
        #expect(store.string(forKey: CmxIrohBrokerBackpressureGate.persistenceKey) == nil)
    }

    private func recordRateLimit(
        gate: CmxIrohBrokerBackpressureGate,
        accountID: String,
        operation: CmxIrohBrokerOperation,
        seconds: Int
    ) async {
        do {
            let _: Bool = try await gate.perform(
                accountID: accountID,
                operation: operation
            ) {
                throw CmxIrohTrustBrokerClientError.rateLimited(
                    code: "rate_limited",
                    retryAfterSeconds: seconds
                )
            }
            Issue.record("Expected the fixture request to be rate limited")
        } catch {}
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "CmxIrohBrokerBackpressureGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class BackpressureGateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func set(_ date: Date) {
        lock.withLock { self.date = date }
    }
}

private actor BackpressureGateProbe {
    private var count = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var requestCountWaiters: [
        (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func request() async throws -> Int {
        count += 1
        let ready = requestCountWaiters.filter { count >= $0.minimum }
        requestCountWaiters.removeAll { count >= $0.minimum }
        for waiter in ready { waiter.continuation.resume() }
        if count == 1 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        throw CmxIrohTrustBrokerClientError.rateLimited(
            code: "rate_limited",
            retryAfterSeconds: 600
        )
    }

    func requestCount() -> Int { count }

    func waitForRequestCount(_ minimum: Int) async {
        guard count < minimum else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((minimum, continuation))
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}
