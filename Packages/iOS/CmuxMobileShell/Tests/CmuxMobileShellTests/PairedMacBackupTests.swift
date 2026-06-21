import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

// Intentional test file-organization exception: the small actors below are
// suite-local fixtures for the backup decorator/restore races, kept inline so
// each race test reads next to the exact fake behavior it relies on.

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

/// Backup double whose records can change mid-session, to model a Mac
/// republishing a fresh route after the once-per-launch restore already ran.
private actor MutableBackup: PairedMacBackingUp {
    private var records: [PairedMacBackupRecord]
    private(set) var fetchCount = 0
    init(records: [PairedMacBackupRecord]) { self.records = records }
    func setRecords(_ records: [PairedMacBackupRecord]) { self.records = records }
    func upload(ops: [PairedMacBackupOp]) async {}
    func fetchAll() async -> [PairedMacBackupRecord]? {
        fetchCount += 1
        return records
    }
    func fetches() -> Int { fetchCount }
}

/// Wraps a real inner store but BLOCKS the first `upsert` until released, so a
/// test can suspend a restore precisely inside its store write (the exact window
/// the sign-out wipe must drain) and prove the wipe is final.
private actor GatedUpsertStore: MobilePairedMacStoring {
    private let inner: MobilePairedMacStore
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var gateArmed = true

    init(inner: MobilePairedMacStore) { self.inner = inner }

    func waitUntilUpsertEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }
    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
    private func awaitRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func upsert(
        macDeviceID: String, displayName: String?, routes: [CmxAttachRoute],
        markActive: Bool, stackUserID: String?, teamID: String?, now: Date
    ) async throws {
        if gateArmed {
            gateArmed = false
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await awaitRelease()
        }
        try await inner.upsert(
            macDeviceID: macDeviceID, displayName: displayName, routes: routes,
            markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }
    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }
    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }
    func setActive(macDeviceID: String) async throws { try await inner.setActive(macDeviceID: macDeviceID) }
    func setCustomization(
        macDeviceID: String, customName: String?, customColor: String?,
        customIcon: String?, now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID, customName: customName, customColor: customColor,
            customIcon: customIcon, now: now)
    }
    func remove(macDeviceID: String) async throws { try await inner.remove(macDeviceID: macDeviceID) }
    func removeAll() async throws { try await inner.removeAll() }
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

    @Test func refreshUpdatingActiveMacRouteKeepsItActive() async throws {
        // Regression: a backup refresh that brings a FRESHER record for the
        // currently-active Mac (e.g. refreshFromBackup right before reconnect)
        // must update its route but NOT clear its active flag, or auto-reconnect
        // loses the user's selected Mac.
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: "mac-a", displayName: "Studio",
            routes: [try route("10.0.0.1", 22)],
            markActive: true, stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )
        // Backup is strictly newer (route changed) and its own active flag is false.
        let backup = FakeBackup(records: [
            try backupRecord("mac-a", host: "10.0.0.99", lastSeenMs: 9_000_000_000_000, active: false),
        ])
        let outcome = await PairedMacRestore(store: inner, backup: backup).run(accountID: "user-1")
        #expect(outcome.restored == 1) // mac-a route refreshed from the fresher backup
        let macA = try await inner.loadAll(stackUserID: "user-1").first { $0.macDeviceID == "mac-a" }
        #expect(macA?.routes.first?.endpoint == .hostPort(host: "10.0.0.99", port: 22)) // route updated
        #expect(macA?.isActive == true) // active flag preserved (not cleared by the refresh)
        #expect(try await inner.activeMac(stackUserID: "user-1")?.macDeviceID == "mac-a")
    }

    @Test func cancelledRestoreDoesNotWriteAfterWipe() async throws {
        // Regression: a sign-out wipe cancels in-flight restores; a restore whose
        // fetch was suspended across the wipe must not write the previous
        // account's Macs back into the emptied local store.
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup(records: [
            try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true),
        ])
        let restore = PairedMacRestore(store: inner, backup: backup)
        let task = Task { await restore.run(accountID: "user-1") }
        task.cancel()
        let outcome = await task.value
        #expect(!outcome.completed) // cancelled restore is not a completed restore
        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty) // nothing written
    }

    @Test func removeAllDrainsRestoreSuspendedInsideUpsert() async throws {
        // The sharper sign-out race: a restore passes its cancellation check and is
        // suspended INSIDE `store.upsert` when the wipe runs. Cancellation does not
        // withdraw that queued write, so `removeAll` must DRAIN the restore (await
        // its completion) BEFORE wiping — otherwise the previous account's Mac lands
        // in the just-emptied store after sign-out.
        let (real, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gated = GatedUpsertStore(inner: real)
        let backing = BackingUpPairedMacStore(
            inner: gated,
            backup: FakeBackup(records: [
                try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true),
            ])
        )

        // Kick a restore via a read; it fetches, then blocks inside the gated upsert.
        let restoreKick = Task { _ = try? await backing.loadAll(stackUserID: "user-1") }
        await gated.waitUntilUpsertEntered()

        // Sign-out wipe while the restore is mid-upsert. It must drain that write
        // (so we release the gate to let it finish) and then leave the store empty.
        let wipe = Task { try await backing.removeAll() }
        await gated.release()
        try await wipe.value
        _ = await restoreKick.value

        #expect(try await real.loadAll(stackUserID: "user-1").isEmpty)
    }

    @Test func restoreAppliesCustomizationsFromBackup() async throws {
        // A rename / color / icon set on another device arrives via the backup and
        // is written into the local store on restore.
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup(records: [
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Mini",
                routes: [try route("10.0.0.1", 22)],
                createdAt: 1_000_000,
                lastSeenAt: 9_000_000_000_000,
                isActive: false,
                customName: "Home Studio",
                customColor: "palette:3",
                customIcon: "🖥️"
            ),
        ])
        _ = await PairedMacRestore(store: inner, backup: backup).run(accountID: "user-1")
        let mac = try await inner.loadAll(stackUserID: "user-1").first { $0.macDeviceID == "mac-a" }
        #expect(mac?.customName == "Home Studio")
        #expect(mac?.customColor == "palette:3")
        #expect(mac?.customIcon == "🖥️")
        // The Mac-reported name is preserved alongside the override.
        #expect(mac?.displayName == "Mini")
        #expect(mac?.resolvedName == "Home Studio")
    }

    @Test func recordEncodesCustomKeysEvenWhenNil() throws {
        // The iOS upload must be AUTHORITATIVE over customizations: the three custom
        // keys are always emitted (null when cleared), so the server can tell an iOS
        // reset-to-Auto (key present, null) from a Mac route-publish (key absent ->
        // preserve). A synthesized encoder would drop nil keys and let a Mac
        // heartbeat clobber the user's saved name/color/icon.
        let cleared = PairedMacBackupRecord(
            macDeviceID: "mac-a", displayName: "Mini", routes: [],
            createdAt: 1, lastSeenAt: 2, isActive: true,
            customName: nil, customColor: nil, customIcon: nil
        )
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(cleared)) as? [String: Any]
        let keys = json ?? [:]
        // Present as keys...
        #expect(keys.keys.contains("customName"))
        #expect(keys.keys.contains("customColor"))
        #expect(keys.keys.contains("customIcon"))
        // ...with explicit JSON null (NSNull), not omitted.
        #expect(keys["customName"] is NSNull)
        #expect(keys["customColor"] is NSNull)
        #expect(keys["customIcon"] is NSNull)

        // A set value round-trips as the string, and decode is lossless either way.
        let set = PairedMacBackupRecord(
            macDeviceID: "mac-a", displayName: "Mini", routes: [],
            createdAt: 1, lastSeenAt: 2, isActive: true,
            customName: "Studio", customColor: "palette:3", customIcon: "🖥️"
        )
        let decoded = try JSONDecoder().decode(
            PairedMacBackupRecord.self, from: try JSONEncoder().encode(set))
        #expect(decoded == set)
        let decodedCleared = try JSONDecoder().decode(
            PairedMacBackupRecord.self, from: try JSONEncoder().encode(cleared))
        #expect(decodedCleared == cleared)
    }

    @Test func setCustomizationPersistsAndPreservesMacData() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: "mac-a", displayName: "Mini",
            routes: [try route("10.0.0.1", 22)], markActive: true,
            stackUserID: "user-1", now: Date(timeIntervalSince1970: 1_000)
        )
        try await inner.setCustomization(
            macDeviceID: "mac-a", customName: "Studio", customColor: "#FF8800",
            customIcon: "desktopcomputer", now: Date(timeIntervalSince1970: 2_000)
        )
        let mac = try await inner.loadAll(stackUserID: "user-1").first
        #expect(mac?.customName == "Studio")
        #expect(mac?.customColor == "#FF8800")
        #expect(mac?.customIcon == "desktopcomputer")
        // setCustomization leaves the Mac's reported name + routes + active intact.
        #expect(mac?.displayName == "Mini")
        #expect(mac?.isActive == true)
        #expect(mac?.routes.count == 1)
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

    @Test func decoratorStampsAndScopesLocalRowsByCurrentTeam() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let team = MutableTeam("team-a")
        // Empty backup so restore is a no-op and only the local upsert matters.
        let store = BackingUpPairedMacStore(
            inner: inner, backup: FakeBackup(), teamIDProvider: { await team.value })

        // Pair a Mac while team-a is selected; the decorator must stamp it team-a.
        try await store.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.1", 22)],
            markActive: true, stackUserID: "user-1", now: Date())
        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])
        // Inner row carries the injected team.
        #expect(try await inner.loadAll(stackUserID: "user-1").first?.teamID == "team-a")

        // Switching to team-b hides the team-a Mac (scoped read), without deleting it.
        await team.set("team-b")
        #expect(try await store.loadAll(stackUserID: "user-1").isEmpty)
        #expect(try await store.activeMac(stackUserID: "user-1") == nil)
        // Back to team-a: still there.
        await team.set("team-a")
        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])
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

    @Test func refreshFromBackupReFetchesStaleSecondaryRouteAfterMemo() async throws {
        // Models the multi-Mac aggregation bug: a secondary Mac relaunches on a
        // new port and republishes, but the once-per-launch restore is memoized
        // so a plain read keeps the stale route. refreshFromBackup must force a
        // re-fetch and apply the fresher route (LWW), so the read-only secondary
        // workspace fetch dials the live port instead of a dead one.
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = PairedMacBackupRecord(
            macDeviceID: "mac-secondary", displayName: "Secondary",
            routes: [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: "100.0.0.9", port: 40000))],
            createdAt: 1_000_000, lastSeenAt: 1_000_000, isActive: false
        )
        let backup = MutableBackup(records: [stale])
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        // First read restores the stale route and memoizes the scope.
        _ = try await store.loadAll(stackUserID: "user-1")
        #expect(await backup.fetches() == 1)

        // The Mac relaunches on a new port and republishes (newer lastSeenAt).
        let fresh = PairedMacBackupRecord(
            macDeviceID: "mac-secondary", displayName: "Secondary",
            routes: [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: "100.0.0.9", port: 50919))],
            createdAt: 1_000_000, lastSeenAt: 2_000_000, isActive: false
        )
        await backup.setRecords([fresh])

        // A plain read is memoized: no re-fetch, route stays stale.
        let memoized = try await store.loadAll(stackUserID: "user-1")
        #expect(await backup.fetches() == 1)
        #expect(memoized.first?.routes.first?.endpoint == .hostPort(host: "100.0.0.9", port: 40000))

        // refreshFromBackup forces a re-fetch and applies the fresher route.
        await store.refreshFromBackup(stackUserID: "user-1")
        #expect(await backup.fetches() == 2)
        let refreshed = try await inner.loadAll(stackUserID: "user-1")
        #expect(refreshed.first?.routes.first?.endpoint == .hostPort(host: "100.0.0.9", port: 50919))
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
