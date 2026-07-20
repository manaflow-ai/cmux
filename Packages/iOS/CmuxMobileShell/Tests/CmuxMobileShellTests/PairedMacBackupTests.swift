import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

private let backupRouteDisclosureDate = Date(timeIntervalSince1970: 2_000_000_000)

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

    private func uploadedRecord(from op: PairedMacBackupOp) -> PairedMacBackupRecord? {
        switch op {
        case .upsert(let record, _), .upsertPreservingCustomizations(let record, _),
             .revive(let record, _), .revivePreservingCustomizations(let record, _):
            return record
        case .delete, .deleteInstance:
            return nil
        }
    }

    private func encodedRecordObject(from op: PairedMacBackupOp) throws -> [String: Any] {
        let body = PairedMacBackupRequestBody(ops: [PairedMacBackupOpWire(
            op: op,
            routeDisclosureDate: backupRouteDisclosureDate
        )])
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        let ops = try #require(json?["ops"] as? [[String: Any]])
        let first = try #require(ops.first)
        return try #require(first["record"] as? [String: Any])
    }

    @Test func backupClientEndpointURLJoinsBasePath() {
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "https://presence.example"
        )?.absoluteString == "https://presence.example/v1/sync/paired-macs")
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "https://presence.example/"
        )?.absoluteString == "https://presence.example/v1/sync/paired-macs")
        #expect(PairedMacBackupClient.endpointURL(
            serviceBaseURL: "http://127.0.0.1:8799/base/"
        )?.absoluteString == "http://127.0.0.1:8799/base/v1/sync/paired-macs")
        #expect(PairedMacBackupClient.endpointURL(serviceBaseURL: "ftp://presence.example") == nil)
    }

    // MARK: - Decorator backup mirroring


    @Test func tokenSourceRejectsExpectedUserMismatchBeforeTokenRead() async {
        let probe = TokenProbe(userIDs: ["user-2"])
        let source = PresenceTokenSource(
            accessToken: { await probe.token() },
            currentUserID: { await probe.currentUserID() }
        )

        #expect(await source.accessToken(expectedUserID: "user-1") == nil)
        #expect(await probe.tokenReads == 0)
    }

    @Test func tokenSourceRejectsUserSwitchDuringTokenRead() async {
        let probe = TokenProbe(userIDs: ["user-1", "user-2"])
        let source = PresenceTokenSource(
            accessToken: { await probe.token() },
            currentUserID: { await probe.currentUserID() }
        )

        #expect(await source.accessToken(expectedUserID: "user-1") == nil)
        #expect(await probe.tokenReads == 1)
    }

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
        #expect(await backup.uploadExpectedUsers() == ["user-1"])
        if let rec = ops.first.flatMap(uploadedRecord(from:)) {
            #expect(rec.macDeviceID == "manual-10.0.0.1:22")
            #expect(rec.isActive == true)
        } else {
            Issue.record("expected a record upload op")
        }
    }

    @Test func backupUploadCanonicalizesUUIDMutationsAndPreservesOpaqueIDs() async throws {
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseUUID = uppercaseUUID.lowercased()
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: uppercaseUUID,
            displayName: "Studio",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 100)
        )
        try await store.remove(
            macDeviceID: uppercaseUUID,
            stackUserID: "user-1",
            teamID: nil
        )

        let ops = await backup.uploadedOps()
        #expect(ops.contains { op in
            uploadedRecord(from: op)?.macDeviceID == lowercaseUUID
        })
        #expect(ops.contains { op in
            if case .delete(let macDeviceID) = op {
                return macDeviceID == lowercaseUUID
            }
            return false
        })

        let opaqueRecord = try backupRecord(
            "Legacy-Mac-ID",
            host: "10.0.0.2",
            lastSeenMs: 200_000,
            active: false
        )
        let body = PairedMacBackupRequestBody(ops: [
            PairedMacBackupOpWire(op: .upsert(opaqueRecord)),
            PairedMacBackupOpWire(op: .delete(macDeviceID: "Legacy-Mac-ID")),
        ])
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        let wireOps = try #require(object["ops"] as? [[String: Any]])
        #expect(wireOps.map { $0["macDeviceID"] as? String } == [
            "Legacy-Mac-ID", "Legacy-Mac-ID",
        ])
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

    @Test func rePairAfterConfirmedDeleteUploadsRevive() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(macDeviceID: "mac-a", displayName: nil, routes: [try route("10.0.0.1", 22)], markActive: true, stackUserID: "user-1", now: Date())
        try await store.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil)
        try await store.upsert(macDeviceID: "mac-a", displayName: nil, routes: [try route("10.0.0.1", 22)], markActive: true, stackUserID: "user-1", now: Date())

        if case .revivePreservingCustomizations(let record, _)? = await backup.uploadedOps().last {
            #expect(record.macDeviceID == "mac-a")
        } else {
            Issue.record("expected re-pair to upload a customization-preserving revive op")
        }
    }

    @Test func failedDeleteUploadLeavesDurableLocalTombstone() async throws {
        // If a Forget tombstone upload fails, the stale live server record must
        // not resurrect on the next restore. The local tombstone outbox is
        // durable and is passed into restore as an additional delete set until a
        // tombstone upload eventually succeeds.
        let suiteName = "paired-mac-pending-delete-\(UUID().uuidString)"
        let pending = UserDefaultsPairedMacPendingDeleteStore(suiteName: suiteName)
        let backup = FakeBackup(
            records: [try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true)],
            failNextUploads: 99
        )
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstStore = BackingUpPairedMacStore(
            inner: inner,
            backup: backup,
            pendingDeleteStore: pending
        )

        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        try await firstStore.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil)
        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty)

        let (freshInner, freshDir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: freshDir) }
        let secondStore = BackingUpPairedMacStore(
            inner: freshInner,
            backup: backup,
            pendingDeleteStore: pending
        )
        let restored = try await secondStore.loadAll(stackUserID: "user-1")

        #expect(restored.isEmpty)
        #expect(try await freshInner.loadAll(stackUserID: "user-1").isEmpty)
        #expect(await backup.uploadedOps().contains {
            if case .delete(let id) = $0 { return id == "mac-a" }
            return false
        })
        await pending.removeAll()
    }

    @Test func failedLocalRemoveDoesNotPersistPendingCloudTombstone() async throws {
        let suiteName = "paired-mac-failed-local-remove-\(UUID().uuidString)"
        let pending = UserDefaultsPairedMacPendingDeleteStore(suiteName: suiteName)
        let backup = FakeBackup(records: [
            try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true),
        ])
        let (real, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await real.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        let failing = GatedUpsertStore(inner: real, failRemove: true)
        let store = BackingUpPairedMacStore(
            inner: failing,
            backup: backup,
            pendingDeleteStore: pending
        )

        await #expect(throws: NSError.self) {
            try await store.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil)
        }
        #expect(await backup.uploadedOps().allSatisfy {
            if case .delete = $0 { return false }
            return true
        })

        let (freshInner, freshDir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: freshDir) }
        let freshStore = BackingUpPairedMacStore(
            inner: freshInner,
            backup: backup,
            pendingDeleteStore: pending
        )
        let restored = try await freshStore.loadAll(stackUserID: "user-1")
        #expect(restored.map(\.macDeviceID) == ["mac-a"])
        await pending.removeAll()
    }

    @Test func durablePendingDeleteCompletesLocalDeleteBeforeRestore() async throws {
        // Simulates a crash after the delete intent was persisted but before the
        // local row was removed. The next read must finish the local delete before
        // flushing the server tombstone, so the stale server live record cannot
        // restore the Mac.
        let suiteName = "paired-mac-crash-delete-intent-\(UUID().uuidString)"
        let pending = UserDefaultsPairedMacPendingDeleteStore(suiteName: suiteName)
        await pending.save(["mac-a"], scope: "user-1\u{0}")
        let backup = FakeBackup(
            records: [try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true)],
            failNextUploads: 99
        )
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date()
        )
        let store = BackingUpPairedMacStore(
            inner: inner,
            backup: backup,
            pendingDeleteStore: pending
        )

        let restored = try await store.loadAll(stackUserID: "user-1")

        #expect(restored.isEmpty)
        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty)
        #expect(await backup.uploadedOps().contains {
            if case .delete(let id) = $0 { return id == "mac-a" }
            return false
        })
        await pending.removeAll()
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

    @Test func restoreAppliesDeleteTombstonesBeforeLiveRecords() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Old Studio",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )
        let backup = FakeBackup(records: [], deletedMacDeviceIDs: ["mac-a"])

        let outcome = await PairedMacRestore(store: inner, backup: backup).run(accountID: "user-1")

        #expect(outcome.completed)
        #expect(outcome.restored == 0)
        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty)
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

    @Test func removeDrainsRestoreSuspendedInsideUpsertBeforeDeletingExistingMac() async throws {
        // Regression: forgetting a Mac while a refresh is suspended inside upsert
        // must leave the Mac forgotten. The delete is authoritative, so `remove`
        // drains the in-flight restore before issuing the final local delete.
        let (real, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await real.upsert(
            macDeviceID: "mac-a",
            displayName: "Old Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )
        let gated = GatedUpsertStore(inner: real)
        let backing = BackingUpPairedMacStore(
            inner: gated,
            backup: FakeBackup(records: [
                try backupRecord("mac-a", host: "10.0.0.2", lastSeenMs: 2_000_000, active: true),
            ])
        )

        let refresh = Task { await backing.refreshFromBackup(stackUserID: "user-1") }
        await gated.waitUntilUpsertEntered()
        let forget = Task { try await backing.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil) }
        await gated.release()
        try await forget.value
        _ = await refresh.value

        #expect(try await real.loadAll(stackUserID: "user-1").isEmpty)
    }

    @Test func boundaryInvalidationRemovesRestoreSuspendedInsideUpsert() async throws {
        // signOut()/team-switch are synchronous, so they invalidate a shared
        // boundary immediately before the actor cancellation task runs. A restore
        // suspended inside `upsert` must notice that invalidation after the write
        // resumes and remove the row it just inserted.
        let (real, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gated = GatedUpsertStore(inner: real)
        let boundary = PairedMacRestoreBoundary()
        let backing = BackingUpPairedMacStore(
            inner: gated,
            backup: FakeBackup(records: [
                try backupRecord("mac-a", host: "10.0.0.1", lastSeenMs: 2_000_000, active: true),
            ]),
            restoreBoundary: boundary
        )

        let restoreKick = Task { _ = try? await backing.loadAll(stackUserID: "user-1") }
        await gated.waitUntilUpsertEntered()
        boundary.invalidate()
        await gated.release()
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

    @Test func routineMirrorUploadsOmitCustomKeysOnWire() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )

        let first = try #require(await backup.uploadedOps().first)
        guard case .upsertPreservingCustomizations = first else {
            guard case .revivePreservingCustomizations = first else {
                Issue.record("routine mirror should preserve server customizations")
                return
            }
            let keys = try encodedRecordObject(from: first)
            #expect(keys.keys.contains("macDeviceID"))
            #expect(!keys.keys.contains("customName"))
            #expect(!keys.keys.contains("customColor"))
            #expect(!keys.keys.contains("customIcon"))
            return
        }
        let keys = try encodedRecordObject(from: first)
        #expect(keys.keys.contains("macDeviceID"))
        #expect(!keys.keys.contains("customName"))
        #expect(!keys.keys.contains("customColor"))
        #expect(!keys.keys.contains("customIcon"))
    }

    @Test func routeRefreshReviveOmitsCustomKeysOnWire() throws {
        let record = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true,
            customName: nil,
            customColor: nil,
            customIcon: nil
        )
        let keys = try encodedRecordObject(from: .revivePreservingCustomizations(record))
        #expect(!keys.keys.contains("customName"))
        #expect(!keys.keys.contains("customColor"))
        #expect(!keys.keys.contains("customIcon"))
    }

    @Test func authoritativeReviveCarriesCustomKeysOnWire() throws {
        let record = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true,
            customName: nil,
            customColor: nil,
            customIcon: nil
        )
        let keys = try encodedRecordObject(from: .revive(record))
        #expect(keys["customName"] is NSNull)
        #expect(keys["customColor"] is NSNull)
        #expect(keys["customIcon"] is NSNull)
    }

    @Test func upsertPreserveOmitsCustomKeysOnWire() throws {
        let record = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true,
            customName: nil,
            customColor: nil,
            customIcon: nil
        )
        let keys = try encodedRecordObject(from: .upsertPreservingCustomizations(record))
        #expect(!keys.keys.contains("customName"))
        #expect(!keys.keys.contains("customColor"))
        #expect(!keys.keys.contains("customIcon"))
    }

    @Test func authoritativeUpsertCarriesCustomKeysOnWire() throws {
        let record = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [],
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true,
            customName: nil,
            customColor: nil,
            customIcon: nil
        )
        let keys = try encodedRecordObject(from: .upsert(record))
        #expect(keys["customName"] is NSNull)
        #expect(keys["customColor"] is NSNull)
        #expect(keys["customIcon"] is NSNull)
    }


    @Test func routineMirrorUploadsUsePreserveModeEvenForTombstoneRevive() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )

        let first = try #require(await backup.uploadedOps().first)
        guard case .revivePreservingCustomizations = first else {
            Issue.record("routine mirror should preserve server customizations")
            return
        }
        let keys = try encodedRecordObject(from: first)
        #expect(keys.keys.contains("macDeviceID"))
        #expect(!keys.keys.contains("customName"))
        #expect(!keys.keys.contains("customColor"))
        #expect(!keys.keys.contains("customIcon"))
    }

    @Test func explicitCustomizationUploadCarriesNullCustomKeysOnWire() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(inner: inner, backup: backup)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mini",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1_000)
        )
        try await store.setCustomization(
            macDeviceID: "mac-a",
            customName: nil,
            customColor: nil,
            customIcon: nil,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )

        let last = try #require(await backup.uploadedOps().last)
        guard case .upsert = last else {
            Issue.record("explicit customization writes should be authoritative")
            return
        }
        let keys = try encodedRecordObject(from: last)
        #expect(keys.keys.contains("customName"))
        #expect(keys.keys.contains("customColor"))
        #expect(keys.keys.contains("customIcon"))
        #expect(keys["customName"] is NSNull)
        #expect(keys["customColor"] is NSNull)
        #expect(keys["customIcon"] is NSNull)
    }

    @Test func backupDecodeDropsUnsupportedRoutesAndMalformedRecords() throws {
        let data = Data("""
        {
          "records": [
            {
              "macDeviceID": "mac-a",
              "displayName": "Studio",
              "routes": [
                {
                  "id": "manual",
                  "kind": "tailscale",
                  "endpoint": { "type": "host_port", "host": "10.0.0.1", "port": 22 },
                  "priority": 0
                },
                {
                  "id": "future",
                  "kind": "future-route",
                  "endpoint": { "type": "future_endpoint", "value": "opaque" },
                  "priority": 1
                }
              ],
              "createdAt": 1,
              "lastSeenAt": 2,
              "isActive": true
            },
            {
              "macDeviceID": 42,
              "routes": [],
              "createdAt": 1,
              "lastSeenAt": 2,
              "isActive": false
            },
            {
              "macDeviceID": "mac-b",
              "displayName": "Mini",
              "routes": [
                {
                  "id": "manual",
                  "kind": "debug_loopback",
                  "endpoint": { "type": "host_port", "host": "127.0.0.1", "port": 9222 },
                  "priority": 0
                }
              ],
              "createdAt": 3,
              "lastSeenAt": 4,
              "isActive": false
            }
          ],
          "deletedMacDeviceIDs": [" mac-gone ", ""]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PairedMacBackupListResponse.self, from: data)

        #expect(decoded.records.map(\.macDeviceID) == ["mac-a", "mac-b"])
        #expect(decoded.records[0].routes.map(\.id) == ["manual"])
        #expect(decoded.records[0].routes.first?.endpoint == .hostPort(host: "10.0.0.1", port: 22))
        #expect(decoded.records[1].routes.first?.endpoint == .hostPort(host: "127.0.0.1", port: 9222))
        #expect(decoded.deletedMacDeviceIDs == ["mac-gone"])
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
            customIcon: "desktopcomputer", stackUserID: "user-1", teamID: nil,
            now: Date(timeIntervalSince1970: 2_000)
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

    @Test func backupRestoreCollapsesUUIDAliasesUnderFreshRouteAuthority() async throws {
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseUUID = uppercaseUUID.lowercased()
        var fresh = PairedMacBackupRecord(
            macDeviceID: lowercaseUUID,
            displayName: "Fresh Studio",
            routes: [try CmxAttachRoute(
                id: "fresh",
                kind: .tailscale,
                endpoint: .hostPort(host: "10.0.0.1", port: 50_902)
            )],
            createdAt: 1_000,
            lastSeenAt: 20_000,
            isActive: false,
            customName: "Fresh Name"
        )
        var stale = PairedMacBackupRecord(
            macDeviceID: uppercaseUUID,
            displayName: "Stale Studio",
            routes: [try CmxAttachRoute(
                id: "stale",
                kind: .tailscale,
                endpoint: .hostPort(host: "10.0.0.1", port: 50_901)
            )],
            createdAt: 500,
            lastSeenAt: 10_000,
            isActive: true,
            customName: "Stale Name"
        )
        // Model legacy server rows decoded before this boundary existed.
        fresh.macDeviceID = lowercaseUUID
        stale.macDeviceID = uppercaseUUID

        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await PairedMacRestore(
            store: inner,
            backup: FakeBackup(records: [fresh, stale])
        ).run(accountID: "user-1")

        let rows = try await inner.loadAll(stackUserID: "user-1")
        let restored = try #require(rows.first)
        #expect(outcome.restored == 1)
        #expect(rows.count == 1)
        #expect(restored.macDeviceID == lowercaseUUID)
        #expect(restored.displayName == "Fresh Studio")
        #expect(restored.customName == "Fresh Name")
        #expect(restored.routes.map(\.id) == ["fresh"])
        #expect(!restored.isActive)
    }

    @Test func legacyUppercaseBackupTombstoneDeletesCanonicalUUIDRow() async throws {
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseUUID = uppercaseUUID.lowercased()
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: lowercaseUUID,
            displayName: "Studio",
            routes: [try route("10.0.0.1", 22)],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 100)
        )

        _ = await PairedMacRestore(
            store: inner,
            backup: FakeBackup(deletedMacDeviceIDs: [uppercaseUUID])
        ).run(accountID: "user-1")

        #expect(try await inner.loadAll(stackUserID: "user-1").isEmpty)
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
        #expect(await backup.fetchExpectedUsers().contains("user-1"))
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

    @Test func upsertMirrorsUsingCapturedTeamScope() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = FakeBackup()
        let team = MutableTeam("team-a")
        let store = BackingUpPairedMacStore(
            inner: inner, backup: backup, teamIDProvider: { await team.value })

        try await store.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.1", 22)],
            markActive: true, stackUserID: "user-1", now: Date())

        await team.set("team-b")
        #expect(await backup.uploadTeams().compactMap { $0 } == ["team-a"])
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
        let lastB = ops.compactMap(uploadedRecord(from:)).last { $0.macDeviceID == "mac-b" }
        let lastA = ops.compactMap(uploadedRecord(from:)).last { $0.macDeviceID == "mac-a" }
        if let lastB { #expect(lastB.isActive) } else { Issue.record("no mac-b upsert mirrored") }
        if let lastA { #expect(!lastA.isActive) } else { Issue.record("no mac-a upsert mirrored") }
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
