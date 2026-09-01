import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing

@testable import CmuxIrxTransport

/// In-memory secure store double for the device-list lease tests.
private actor InMemorySecureCredentialStore: CmxIrohSecureCredentialStoring {
    private var records: [String: Data] = [:]

    func read(account: String) async throws -> Data? {
        records[account]
    }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) async throws {
        records[account] = data
    }

    func delete(account: String) async throws {
        records[account] = nil
    }

    func deleteAll() async throws {
        records.removeAll()
    }

    var recordCount: Int { records.count }
}

private func testJournal(_ category: String) -> IrxJournal {
    IrxJournal(subsystem: "dev.cmux.tests", category: category)
}

private func makeSnapshot(
    entries: [String: IrxDeviceListEntry],
    rev: Int = 3,
    ttlSeconds: Int = 86_400,
    receivedAtWall: Date = Date(),
    receivedAtMonotonic: ContinuousClock.Instant = .now
) -> IrxDeviceListSnapshot {
    IrxDeviceListSnapshot(
        entries: entries,
        rev: rev,
        issuedAt: receivedAtWall,
        ttlSeconds: ttlSeconds,
        receivedAtWall: receivedAtWall,
        receivedAtMonotonic: receivedAtMonotonic
    )
}

@Suite("device list snapshot freshness")
struct IrxDeviceListSnapshotTests {
    @Test func freshInsideTTLStaleAfter() {
        let base = ContinuousClock.now
        let snapshot = makeSnapshot(
            entries: [:], ttlSeconds: 100, receivedAtMonotonic: base)
        #expect(snapshot.isFresh(now: base))
        #expect(snapshot.isFresh(now: base.advanced(by: .seconds(99))))
        #expect(!snapshot.isFresh(now: base.advanced(by: .seconds(100))))
        #expect(!snapshot.isFresh(now: base.advanced(by: .seconds(101))))
    }

    @Test func monotonicRegressionIsStale() {
        // A "now" EARLIER than receipt can only mean a broken anchor;
        // fail closed instead of treating it as maximally fresh.
        let base = ContinuousClock.now
        let snapshot = makeSnapshot(
            entries: [:], ttlSeconds: 100, receivedAtMonotonic: base)
        #expect(!snapshot.isFresh(now: base.advanced(by: .seconds(-1))))
    }

    @Test func restampOnlyMovesForward() {
        let base = ContinuousClock.now
        let issuedAt = Date(timeIntervalSince1970: 100)
        let snapshot = makeSnapshot(
            entries: [:], rev: 5, ttlSeconds: 100,
            receivedAtWall: issuedAt, receivedAtMonotonic: base)
        #expect(snapshot.restamped(
            rev: 4, issuedAt: issuedAt.addingTimeInterval(1),
            receivedAtWall: issuedAt.addingTimeInterval(1),
            receivedAtMonotonic: base) == nil)
        #expect(snapshot.restamped(
            rev: 6, issuedAt: issuedAt.addingTimeInterval(1),
            receivedAtWall: issuedAt.addingTimeInterval(1),
            receivedAtMonotonic: base) == nil)
        #expect(snapshot.restamped(
            rev: 5, issuedAt: issuedAt, receivedAtWall: issuedAt,
            receivedAtMonotonic: base) == nil)
        #expect(snapshot.restamped(
            rev: 5, issuedAt: issuedAt.addingTimeInterval(-1),
            receivedAtWall: issuedAt.addingTimeInterval(-1),
            receivedAtMonotonic: base) == nil)
        let stamped = snapshot.restamped(
            rev: 5, issuedAt: issuedAt.addingTimeInterval(1),
            receivedAtWall: issuedAt.addingTimeInterval(1),
            receivedAtMonotonic: base.advanced(by: .seconds(50)))
        #expect(stamped?.rev == 5)
        #expect(stamped?.isFresh(now: base.advanced(by: .seconds(120))) == true)
    }
}

@Suite("device list store persistence")
struct IrxDeviceListStoreTests {
    private func entry(revoked: Bool = false, status: String = "active") -> IrxDeviceListEntry {
        IrxDeviceListEntry(deviceID: "d-1", status: status, revoked: revoked)
    }

    @Test func persistedLeaseRoundTripsFresh() async {
        let secureStore = InMemorySecureCredentialStore()
        let wall = Date()
        let store = IrxDeviceListStore(
            secureStore: secureStore,
            accountID: "acct-1",
            backendHost: "broker.example",
            journal: testJournal("device-list-roundtrip"),
            wallNow: { wall.addingTimeInterval(60) },
            monotonicNow: { .now }
        )
        await store.persist(
            makeSnapshot(entries: ["ep1": entry()], rev: 9, receivedAtWall: wall))
        let loaded = await store.loadPersisted()
        #expect(loaded?.rev == 9)
        #expect(loaded?.entries["ep1"]?.deviceID == "d-1")
        // 60s of wall elapsed out of a day-long TTL: still fresh.
        #expect(loaded?.isFresh(now: .now) == true)
    }

    @Test func persistedLeaseExpiresByWallElapsed() async {
        let secureStore = InMemorySecureCredentialStore()
        let wall = Date()
        let store = IrxDeviceListStore(
            secureStore: secureStore,
            accountID: "acct-1",
            backendHost: "broker.example",
            journal: testJournal("device-list-expiry"),
            wallNow: { wall.addingTimeInterval(90_000) },  // > 86_400
            monotonicNow: { .now }
        )
        await store.persist(
            makeSnapshot(entries: ["ep1": entry()], receivedAtWall: wall))
        let loaded = await store.loadPersisted()
        // The stale lease is RETURNED (so callers can fail closed) but is
        // not fresh.
        #expect(loaded != nil)
        #expect(loaded?.isFresh(now: .now) == false)
    }

    @Test func wallClockRollbackFailsClosed() async {
        let secureStore = InMemorySecureCredentialStore()
        let wall = Date()
        let store = IrxDeviceListStore(
            secureStore: secureStore,
            accountID: "acct-1",
            backendHost: "broker.example",
            journal: testJournal("device-list-rollback"),
            wallNow: { wall.addingTimeInterval(-3_600) },  // clock ran backward
            monotonicNow: { .now }
        )
        await store.persist(
            makeSnapshot(entries: ["ep1": entry()], receivedAtWall: wall))
        let loaded = await store.loadPersisted()
        #expect(loaded != nil)
        #expect(loaded?.isFresh(now: .now) == false)
    }

    @Test func clearRemovesTheLease() async {
        let secureStore = InMemorySecureCredentialStore()
        let store = IrxDeviceListStore(
            secureStore: secureStore,
            accountID: "acct-1",
            backendHost: "broker.example",
            journal: testJournal("device-list-clear")
        )
        await store.persist(makeSnapshot(entries: ["ep1": entry()]))
        await store.clear()
        #expect(await store.loadPersisted() == nil)
        #expect(await secureStore.recordCount == 0)
    }

    @Test func scopeIsPerAccountAndBackend() {
        let a = IrxDeviceListStore.storageAccount(
            accountID: "acct-1", backendHost: "broker.example")
        let b = IrxDeviceListStore.storageAccount(
            accountID: "acct-2", backendHost: "broker.example")
        let c = IrxDeviceListStore.storageAccount(
            accountID: "acct-1", backendHost: "staging.example")
        #expect(a != b)
        #expect(a != c)
    }

    @Test func scopeEncodingIsInjectiveAcrossDelimiterLikeValues() {
        let first = IrxDeviceListStore.storageAccount(
            accountID: "a-b", backendHost: "c")
        let second = IrxDeviceListStore.storageAccount(
            accountID: "a", backendHost: "b-c")
        #expect(first != second)
    }
}

@Suite("list judge")
struct IrxListJudgeTests {
    private let endpoint = String(repeating: "ab", count: 32)

    private func deniedCode(
        _ judgment: IrxGrantJudgment,
        grant: String? = nil,
        endpoint: String
    ) -> IrxCloseCode? {
        do {
            _ = try judgment(grant, endpoint)
            return nil
        } catch let denial as IrxAdmissionDenied {
            return denial.code
        } catch {
            return nil
        }
    }

    @Test func allowsFreshListedUnrevokedPeer() throws {
        let box = IrxDeviceListCurrent()
        box.replace(
            makeSnapshot(entries: [
                endpoint: IrxDeviceListEntry(
                    deviceID: "d-9", status: "seeded", revoked: false,
                    bindingID: "b-9", tag: "default")
            ]))
        let judge = IrxListJudge(current: box, journal: testJournal("judge-allow"))
        // The grant is ignored entirely: nil and non-nil both admit.
        let peer = try judge.judgment()(nil, endpoint)
        #expect(peer.deviceID == "d-9")
        #expect(peer.bindingID == "b-9")
        #expect(peer.endpointIDHex == endpoint)
        let withGrant = try judge.judgment()("some-legacy-grant", endpoint)
        #expect(withGrant.deviceID == "d-9")
    }

    @Test func deniesUnknownEndpoint() {
        let box = IrxDeviceListCurrent()
        box.replace(
            makeSnapshot(entries: [
                endpoint: IrxDeviceListEntry(status: "active", revoked: false)
            ]))
        let judge = IrxListJudge(current: box, journal: testJournal("judge-unknown"))
        #expect(
            deniedCode(judge.judgment(), endpoint: String(repeating: "cd", count: 32))
                == .invalidGrant)
    }

    @Test func deniesRevokedEntry() {
        let box = IrxDeviceListCurrent()
        box.replace(
            makeSnapshot(entries: [
                endpoint: IrxDeviceListEntry(status: "active", revoked: true)
            ]))
        let judge = IrxListJudge(current: box, journal: testJournal("judge-revoked"))
        #expect(deniedCode(judge.judgment(), endpoint: endpoint) == .revoked)
    }

    @Test func deniesAbsentSnapshot() {
        let box = IrxDeviceListCurrent()
        let judge = IrxListJudge(current: box, journal: testJournal("judge-absent"))
        #expect(deniedCode(judge.judgment(), endpoint: endpoint) == .invalidGrant)
    }

    @Test func deniesStaleLease() {
        let base = ContinuousClock.now
        let box = IrxDeviceListCurrent()
        box.replace(
            makeSnapshot(
                entries: [
                    endpoint: IrxDeviceListEntry(status: "active", revoked: false)
                ],
                ttlSeconds: 100,
                receivedAtMonotonic: base
            ))
        let judge = IrxListJudge(
            current: box,
            journal: testJournal("judge-stale"),
            now: { base.advanced(by: .seconds(101)) }
        )
        #expect(deniedCode(judge.judgment(), endpoint: endpoint) == .invalidGrant)
    }

    @Test func deniesAfterWallClockRollbackRehydration() async {
        // Full path: persist, roll the wall clock back, load, judge.
        let secureStore = InMemorySecureCredentialStore()
        let wall = Date()
        let store = IrxDeviceListStore(
            secureStore: secureStore,
            accountID: "acct-1",
            backendHost: "broker.example",
            journal: testJournal("judge-rollback"),
            wallNow: { wall.addingTimeInterval(-60) },
            monotonicNow: { .now }
        )
        await store.persist(
            makeSnapshot(
                entries: [
                    endpoint: IrxDeviceListEntry(status: "active", revoked: false)
                ],
                receivedAtWall: wall
            ))
        let box = IrxDeviceListCurrent()
        box.replace(await store.loadPersisted())
        let judge = IrxListJudge(current: box, journal: testJournal("judge-rollback2"))
        #expect(deniedCode(judge.judgment(), endpoint: endpoint) == .invalidGrant)
    }

    @Test func clearFailsClosedImmediately() throws {
        let box = IrxDeviceListCurrent()
        box.replace(
            makeSnapshot(entries: [
                endpoint: IrxDeviceListEntry(status: "active", revoked: false)
            ]))
        let judge = IrxListJudge(current: box, journal: testJournal("judge-clear"))
        _ = try judge.judgment()(nil, endpoint)
        box.clear()
        #expect(deniedCode(judge.judgment(), endpoint: endpoint) == .invalidGrant)
    }
}

@Suite("grantless hello wire compatibility")
struct IrxHelloGrantlessTests {
    @Test func legacyGrantBearingHelloStillParses() throws {
        let legacy = Data(
            #"{"v":1,"proto":"cmux/irx/1","grant":"jws-material"}"#.utf8)
        let hello = try JSONDecoder().decode(IrxHello.self, from: legacy)
        #expect(hello.grant == "jws-material")
    }

    @Test func grantlessHelloRoundTrips() throws {
        let encoded = try JSONEncoder().encode(IrxHello())
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("grant"))
        let hello = try JSONDecoder().decode(IrxHello.self, from: encoded)
        #expect(hello.grant == nil)
        #expect(hello.proto == IrxProtocol.alpn)
    }

    @Test func legacyGrantJudgeDeniesGrantlessHello() {
        let judge = IrxGrantJudge(
            acceptor: Self.dummyAcceptor(),
            trustProvider: { nil }
        )
        do {
            _ = try judge.judgment()(nil, String(repeating: "ab", count: 32))
            Issue.record("grantless hello must not pass the legacy grant judge")
        } catch let denial as IrxAdmissionDenied {
            #expect(denial.code == .invalidGrant)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private static func dummyAcceptor() -> CmxIrohGrantPeer {
        // A structurally valid acceptor tuple; the grantless guard fires
        // before any of it is inspected.
        let endpointID = try! CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32))
        return CmxIrohGrantPeer(
            bindingID: "b-test",
            deviceID: "d-test",
            tag: "test",
            platform: .mac,
            endpointID: endpointID,
            identityGeneration: 1
        )
    }
}
