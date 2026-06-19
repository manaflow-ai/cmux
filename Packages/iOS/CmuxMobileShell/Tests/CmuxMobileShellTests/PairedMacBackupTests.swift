import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// In-memory backup double: records uploaded ops, counts fetches, and can be
/// told to fail the first N fetches (to exercise the retry path).
private actor FakeBackup: PairedMacBackingUp {
    private(set) var uploaded: [PairedMacBackupOp] = []
    private(set) var fetchCount = 0
    private let records: [PairedMacBackupRecord]
    private var failNextFetches: Int

    init(records: [PairedMacBackupRecord] = [], failNextFetches: Int = 0) {
        self.records = records
        self.failNextFetches = failNextFetches
    }

    func upload(ops: [PairedMacBackupOp]) async {
        uploaded.append(contentsOf: ops)
    }

    func fetchAll() async -> [PairedMacBackupRecord]? {
        fetchCount += 1
        if failNextFetches > 0 {
            failNextFetches -= 1
            return nil
        }
        return records
    }

    func uploadedOps() -> [PairedMacBackupOp] { uploaded }
    func fetches() -> Int { fetchCount }
}

/// Mutable team holder so a test can simulate a team switch mid-session.
private actor MutableTeam {
    var value: String
    init(_ value: String) { self.value = value }
    func set(_ value: String) { self.value = value }
}

@Suite struct PairedMacBackupTests {
    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func route(_ host: String, _ port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }

    private func backupRecord(_ id: String, host: String, lastSeenMs: Double, active: Bool) throws -> PairedMacBackupRecord {
        PairedMacBackupRecord(
            macDeviceID: id,
            displayName: id,
            routes: [try route(host, 22)],
            createdAt: lastSeenMs,
            lastSeenAt: lastSeenMs,
            isActive: active
        )
    }

    // MARK: - Decorator backup mirroring

    @Test func upsertForwardsAndUploads() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "manual-10.0.0.1:22",
            displayName: "Studio",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )

        // Forwarded to the local store.
        let local = try await inner.loadAll(stackUserID: "user-1")
        #expect(local.map(\.macDeviceID) == ["manual-10.0.0.1:22"])
        // Mirrored to the backup.
        let ops = await backup.uploadedOps()
        #expect(ops.count == 1)
        if case .upsert(let rec) = ops.first {
            #expect(rec.macDeviceID == "manual-10.0.0.1:22")
            #expect(rec.isActive == true)
        } else {
            Issue.record("expected an upsert op")
        }
    }

    @Test func anonymousUpsertIsNotBackedUp() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        // No signed-in account → nothing to scope a per-user backup to.
        try await store.upsert(
            macDeviceID: "manual-10.0.0.9:22",
            displayName: nil,
            routes: [try route("10.0.0.9", 22)],
            markActive: true,
            stackUserID: nil,
            now: Date()
        )
        #expect(await backup.uploadedOps().isEmpty)
    }

    @Test func removeUploadsDeleteButRemoveAllDoesNot() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(macDeviceID: "mac-a", displayName: nil, routes: [try route("10.0.0.1", 22)], markActive: true, stackUserID: "user-1", now: Date())
        try await store.remove(macDeviceID: "mac-a")
        try await store.removeAll()

        let ops = await backup.uploadedOps()
        // One upsert + one delete; removeAll (sign-out wipe) must NOT touch the server.
        #expect(ops.contains { if case .delete(let id) = $0 { return id == "mac-a" } else { return false } })
        #expect(ops.count == 2)
    }

    // MARK: - Restore

    @Test func loadAllRestoresOnceForSignedInAccount() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fresh local store; backup has two saved hosts (reinstall scenario).
        let backup = FakeBackup(records: [
            try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true),
            try backupRecord("mac-b", host: "10.0.0.2", lastSeenMs: 1_000_000, active: false),
        ])
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        let first = try await store.loadAll(stackUserID: "user-1")
        #expect(Set(first.map(\.macDeviceID)) == ["mac-a", "mac-b"])
        // The previously-active host is restored active (auto-reconnect target).
        #expect(try await inner.activeMac(stackUserID: "user-1")?.macDeviceID == "mac-a")
        // Backup uploads from restore must not echo (restore writes inner directly).
        #expect(await backup.uploadedOps().isEmpty)
    }

    @Test func restoreKeepsNewerLocalAndDoesNotHijackActive() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Local already has an active host edited recently.
        try await inner.upsert(
            macDeviceID: "mac-local",
            displayName: "Local",
            routes: [try route("192.168.0.5", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 5_000)
        )
        // Local copy of mac-shared is NEWER than the backup's.
        try await inner.upsert(
            macDeviceID: "mac-shared",
            displayName: "Shared local",
            routes: [try route("192.168.0.6", 22)],
            markActive: false,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 5_000)
        )

        let backup = FakeBackup(records: [
            // Older than local → must be skipped.
            try backupRecord("mac-shared", host: "10.9.9.9", lastSeenMs: 1_000_000, active: true),
            // Missing locally → inserted, but inactive because local already has an active host.
            try backupRecord("mac-remote", host: "10.0.0.3", lastSeenMs: 9_000_000_000, active: true),
        ])

        let outcome = await PairedMacRestore(store: inner, backup: backup).run(accountID: "user-1")
        #expect(outcome.restored == 1) // only mac-remote written

        // Local active selection preserved.
        #expect(try await inner.activeMac(stackUserID: "user-1")?.macDeviceID == "mac-local")
        // mac-shared kept the newer local route (not the backup's 10.9.9.9).
        let shared = try await inner.loadAll(stackUserID: "user-1").first { $0.macDeviceID == "mac-shared" }
        #expect(shared?.routes.first?.endpoint == .hostPort(host: "192.168.0.6", port: 22))
    }

    @Test func emptyBackupLeavesLocalUntouched() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(macDeviceID: "mac-x", displayName: nil, routes: [try route("10.0.0.1", 22)], markActive: true, stackUserID: "user-1", now: Date())
        let outcome = await PairedMacRestore(store: inner, backup: FakeBackup(records: [])).run(accountID: "user-1")
        #expect(outcome.completed)
        #expect(outcome.restored == 0)
        #expect(try await inner.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-x"])
    }

    @Test func failedFetchRetriesOnNextRead() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // First fetch fails (transient), second succeeds.
        let backup = FakeBackup(records: [try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true)], failNextFetches: 1)
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        let firstRead = try await store.loadAll(stackUserID: "user-1")
        #expect(firstRead.isEmpty) // fetch failed, nothing restored
        let secondRead = try await store.loadAll(stackUserID: "user-1")
        #expect(secondRead.map(\.macDeviceID) == ["mac-a"]) // retried and restored
        #expect(await backup.fetches() == 2) // not memoized after the failure
    }

    @Test func signOutThenSameAccountSignInReRestores() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup(records: [try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true)])
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])
        // Sign-out wipe.
        try await store.removeAll()
        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty)
        // Same-account sign-in in the same launch must restore again, not skip.
        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])
        #expect(await backup.fetches() == 2)
    }

    @Test func teamSwitchReRestores() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup(records: [try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true)])
        let team = MutableTeam("team-a")
        let store = BackingUpPairedMacStore(inner: inner, backup: backup, teamIDProvider: { await team.value })

        _ = try await store.loadAll(stackUserID: "user-1")
        _ = try await store.loadAll(stackUserID: "user-1") // same scope → memoized, no re-fetch
        #expect(await backup.fetches() == 1)
        await team.set("team-b")
        _ = try await store.loadAll(stackUserID: "user-1") // new (account, team) scope → re-restore
        #expect(await backup.fetches() == 2)
    }

    @Test func setActiveMirrorsScopeToBackup() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(macDeviceID: "mac-a", displayName: nil, routes: [try route("10.0.0.1", 22)], markActive: true, stackUserID: "user-1", now: Date())
        try await store.upsert(macDeviceID: "mac-b", displayName: nil, routes: [try route("10.0.0.2", 22)], markActive: false, stackUserID: "user-1", now: Date())
        try await store.setActive(macDeviceID: "mac-b")

        // The last upload (from setActive's scope mirror) marks mac-b active and mac-a inactive.
        let ops = await backup.uploadedOps()
        let lastB = ops.last { if case .upsert(let r) = $0 { return r.macDeviceID == "mac-b" } else { return false } }
        let lastA = ops.last { if case .upsert(let r) = $0 { return r.macDeviceID == "mac-a" } else { return false } }
        if case .upsert(let b)? = lastB { #expect(b.isActive) } else { Issue.record("no mac-b upsert mirrored") }
        if case .upsert(let a)? = lastA { #expect(!a.isActive) } else { Issue.record("no mac-a upsert mirrored") }
    }

    // MARK: - Flag

    @Test func flagResolvesEnvThenDefaultsThenBuild() {
        #expect(MobilePairedMacBackup.resolved(environment: ["CMUX_MOBILE_PAIRED_MAC_BACKUP": "1"], defaults: .standard, isDebugBuild: false).isEnabled)
        #expect(!MobilePairedMacBackup.resolved(environment: ["CMUX_MOBILE_PAIRED_MAC_BACKUP": "0"], defaults: .standard, isDebugBuild: true).isEnabled)
        // No override → build flavor decides.
        let empty = UserDefaults(suiteName: "paired-mac-backup-flag-test-\(UUID().uuidString)")!
        #expect(MobilePairedMacBackup.resolved(environment: [:], defaults: empty, isDebugBuild: true).isEnabled)
        #expect(!MobilePairedMacBackup.resolved(environment: [:], defaults: empty, isDebugBuild: false).isEnabled)
    }
}
