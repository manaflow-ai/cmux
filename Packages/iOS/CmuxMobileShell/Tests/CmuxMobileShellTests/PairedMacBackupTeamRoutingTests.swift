import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for the backup-team routing of a forget.
///
/// A tombstone's destination is correctness-critical: sent to the wrong team's
/// backup it deletes an unrelated same-pairing record there while the real
/// backup survives to resurrect the forgotten Mac. A team-less row shown under
/// a selected team (legacy visibility) proves nothing about where its backup
/// lives — the display team is arbitrary — and a nil team is not sendable
/// either, because the server resolves nil from its CURRENT account state,
/// which can differ from where the record was stored. With no VERIFIED
/// destination (no persisted upload/restore echo), the tombstone must be
/// PARKED, and it flushes only once an echo recovers the real destination.
@MainActor
@Suite struct PairedMacBackupTeamRoutingTests {
    @Test func unmappedTeamlessTombstoneParksUntilItsDestinationIsVerified() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less local row seeded RAW (no upload ever echoed a destination
        // for it — the pre-echo population).
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let backup = FakeBackup()
        // "team-shown" is selected the whole time, so the team-less row is shown
        // under it (legacy visibility) and the user forgets it from there.
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        let ok = await composite.forgetHiddenComputer(hidden)

        #expect(ok)
        // Local team-less row deleted under its own key.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" && $0.teamID == nil })

        // No verified destination exists, so the tombstone must NOT have been
        // uploaded anywhere: not to the display team, and never with a guessed
        // nil team the server would re-resolve.
        let deletesSent = await backup.uploadedOps().contains {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }
        #expect(!deletesSent)
    }

    /// A PARKED tombstone is a forget the user was told succeeded. When a later
    /// restore of a CONCRETE team returns the forgotten pairing, that snapshot
    /// is the destination echo the parked intent was waiting for: the pairing's
    /// backup provably lives in that team. The restore must not resurrect the
    /// row locally, and the parked tombstone must resolve to the verified team
    /// and flush, deleting the backup — otherwise every future restore brings
    /// the supposedly forgotten computer back.
    @Test func concreteTeamRestoreResolvesAndFlushesParkedTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less local row seeded RAW (no upload echo ever recorded), whose
        // backup actually lives in team-shown's per-team DO.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let backup = FakeBackup(records: [
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 1_000,
                lastSeenAt: 9_000_000_000_000,
                isActive: false
            ),
        ])
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The forget parks the tombstone: no verified destination exists yet.
        let ok = await composite.forgetHiddenComputer(hidden)
        #expect(ok)

        // A later restore of the CONCRETE selected team returns the pairing and
        // echoes the verified team.
        await store.refreshFromBackup(stackUserID: "user-1")

        // The forgotten row was NOT resurrected locally...
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
        // ...and the parked tombstone resolved to the echoed team and flushed:
        // the delete went out, addressed to team-shown.
        let batches = await backup.uploadBatches()
        let teams = await backup.uploadTeams()
        let deleteBatchIndex = batches.firstIndex { batch in
            batch.contains {
                switch $0 {
                case .delete(let macDeviceID): return macDeviceID == "mac-a"
                case .deleteInstance(let macDeviceID, _): return macDeviceID == "mac-a"
                default: return false
                }
            }
        }
        #expect(deleteBatchIndex != nil)
        if let deleteBatchIndex {
            #expect(teams.indices.contains(deleteBatchIndex))
            #expect(teams[deleteBatchIndex] == "team-shown")
        }
    }

    /// A forget's tombstones must cover backup records the phone never restored
    /// locally. Backups live in PER-TEAM Durable Objects; after a reinstall (or
    /// simply never selecting a team) only the current team's backup has been
    /// restored, so `loadAllInstances` — a purely LOCAL enumeration — cannot see
    /// the same Mac's records in other teams' backups. The wildcard revoke is
    /// account-wide, so those records now describe a computer whose bindings are
    /// all dead; without an account-wide tombstone, switching to that team later
    /// restores it as an unremovable ghost.
    @Test func forgetCoversOtherTeamsBackupRecordsItNeverRestoredLocally() async throws {
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The forgotten Mac has a local row ONLY in team A. Team B's backup —
        // never restored on this phone — holds the same device untagged AND
        // under a tag this phone never saw locally.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let remoteUntagged = PairedMacBackupRecord(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            createdAt: 1_000,
            lastSeenAt: 9_000_000_000_000,
            isActive: false
        )
        var remoteTagged = remoteUntagged
        remoteTagged.instanceTag = "feature"
        let backup = FakeBackup(recordsByTeam: [
            "team-a": [remoteUntagged],
            "team-b": [remoteUntagged, remoteTagged],
        ])
        let team = TeamBox()
        team.value = "team-a"
        let store = BackingUpPairedMacStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value }),
            backup: backup,
            teamIDProvider: { team.value }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        let ok = await composite.forgetHiddenComputer(hidden)
        #expect(ok)

        // The user switches to team B, whose backup was never restored here.
        team.value = "team-b"
        await store.refreshFromBackup(stackUserID: "user-1")

        // Neither of team B's records may come back as a local row: every
        // binding of the device was revoked by the wildcard forget.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
        // And team B's backup records were deleted, not merely hidden: the
        // forget's account-wide tombstone flushes to team B once its snapshot
        // proves it holds the device.
        let batches = await backup.uploadBatches()
        let teams = await backup.uploadTeams()
        var deletedUntaggedInTeamB = false
        var deletedTaggedInTeamB = false
        for (index, batch) in batches.enumerated() where teams.indices.contains(index) && teams[index] == "team-b" {
            for op in batch {
                switch op {
                case .delete(let macDeviceID) where macDeviceID == "mac-a":
                    deletedUntaggedInTeamB = true
                case .deleteInstance(let macDeviceID, let instanceTag)
                    where macDeviceID == "mac-a" && instanceTag == "feature":
                    deletedTaggedInTeamB = true
                default:
                    break
                }
            }
        }
        #expect(deletedUntaggedInTeamB)
        #expect(deletedTaggedInTeamB)
    }

    /// The upload echo must be keyed by the ROW's stored team, not the live
    /// display scope. `loadAll(teamID:)` deliberately includes legacy team-less
    /// rows, so a team-less row mirrored while team A is selected would save
    /// its verified destination under a team-A key — and the later forget,
    /// which looks the mapping up with the row's actual nil team, misses it
    /// and merely PARKS the tombstone. If the network is unavailable for the
    /// echo-time recovery (or that team's restore is already memoized), the
    /// delete never reaches the server and other devices restore the
    /// forgotten computer.
    @Test func mirrorEchoKeysByTheRowsOwnTeamScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A legacy TEAM-LESS row.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { "team-a" }),
            backup: backup,
            teamIDProvider: { "team-a" }
        )
        // A routine mirror (active-host flip) while team A is selected: the
        // server echo verifies the record's backup lives in team A. The row's
        // own scope stays team-less.
        try await store.setActive(macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil)
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The network drops before the forget: the echo-time recovery path is
        // unavailable, so only a ROUTED tombstone (using the persisted echo)
        // can deliver the delete.
        let deletesBefore = await backup.uploadedOps().count
        await backup.setFailNextFetches(99)

        let ok = await composite.forgetHiddenComputer(hidden)

        #expect(ok)
        // The persisted echo routed the tombstone to team A as part of the
        // forget itself — no fetch required.
        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        var routedDelete = false
        var opIndex = 0
        for (batchIndex, batch) in await backup.uploadBatches().enumerated() {
            for op in batch {
                defer { opIndex += 1 }
                guard opIndex >= deletesBefore else { continue }
                switch op {
                case .delete(let macDeviceID) where macDeviceID == "mac-a":
                    if teams.indices.contains(batchIndex), teams[batchIndex] == "team-a" {
                        routedDelete = true
                    }
                default:
                    break
                }
            }
        }
        #expect(routedDelete)
        _ = ops
    }

    /// A parked delete must not tombstone a pairing revived DURING its upload.
    /// The store is a reentrant actor: while the parked flush is suspended on
    /// the network, a re-pair can clear the same intent and upload a revive;
    /// if the older delete lands after that revive server-side, the new record
    /// is wiped and nothing remains to repair it.
    @Test func parkedDeleteRacingARevivalRepairsTheBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less local row seeded RAW; its backup lives in team-shown.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let backup = FakeBackup(recordsByTeam: [
            "team-shown": [
                PairedMacBackupRecord(
                    macDeviceID: "mac-a",
                    displayName: "Desk Mac",
                    routes: [try Self.route("100.82.214.112")],
                    createdAt: 1_000,
                    lastSeenAt: 9_000_000_000_000,
                    isActive: false
                ),
            ],
        ])
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // While the parked delete is suspended in its upload (the forget's
        // post-cleanup refresh restores the verified team, whose echo flushes
        // the parked intent), the user re-pairs the same Mac: the revive
        // clears the parked intent and uploads the record — and then the older
        // delete lands.
        await backup.setOnDeleteUpload { [store] in
            try? await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try! Self.route("100.82.214.112")],
                instanceTag: nil,
                markActive: false,
                stackUserID: "user-1",
                teamID: nil,
                now: Date(timeIntervalSince1970: 3)
            )
        }
        // The forget PARKS the tombstone (team-less unmapped row), then its
        // refresh restores team-shown and flushes the parked delete — into the
        // armed race.
        #expect(await composite.forgetHiddenComputer(hidden))

        // The re-paired Mac's backup record must survive the stale delete.
        let snapshot = await backup.fetchSnapshot(teamID: "team-shown", expectedUserID: "user-1")
        #expect(snapshot?.records.contains { $0.macDeviceID == "mac-a" } == true)
    }

    /// The account-wide parked intent must exist BEFORE the first suspension
    /// that permits a revive. The batch's local deletes await the inner store;
    /// a Mac re-registering during that window clears the routed tombstone and
    /// uploads a revive — but cannot clear a parked intent that has not been
    /// created yet. Inserting it afterwards leaves a stale account-wide
    /// tombstone that suppresses the freshly revived pairing in every restore.
    @Test func revivalDuringLocalDeleteAlsoCancelsTheAccountWideIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let hookedInner = RemoveHookStore(inner: base)
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: hookedInner,
            backup: FakeBackup(),
            teamIDProvider: { "team-shown" },
            pendingDeleteStore: pending
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The still-online Mac re-registers exactly while the forget's local
        // delete is suspended in the inner store.
        await hookedInner.setOnRemoveExactScope { [store] in
            try? await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try! Self.route("100.82.214.112")],
                instanceTag: nil,
                markActive: false,
                stackUserID: "user-1",
                teamID: nil,
                now: Date(timeIntervalSince1970: 3)
            )
        }

        _ = await composite.forgetHiddenComputer(hidden)

        // The revive must have cancelled EVERY tombstone covering the pairing —
        // routed and account-wide alike. A surviving intent would suppress the
        // re-registered Mac's backup record in every future restore.
        var survivingIntents: [String] = []
        for scope in await pending.storedScopes() {
            for raw in await pending.load(scope: scope) where raw.contains("mac-a") {
                survivingIntents.append(raw)
            }
        }
        #expect(survivingIntents.isEmpty)
    }

    /// Retiring a flushed tombstone must not consume a NEWER identical intent.
    /// The flush suspends again after its delete upload (mapping cleanup,
    /// corrective revives); a re-pair plus a second forget during that window
    /// re-adds the identical encoded record, and a set subtraction computed
    /// afterwards would silently erase the second forget's intent — if its own
    /// upload failed, the backup keeps the revived record with no tombstone
    /// left to retry.
    @Test func flushRetirementKeepsANewerIdenticalTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = FakeBackup(recordsByTeam: ["team-a": []])
        let pending = InMemoryPairedMacPendingDeleteStore()
        let hookedTeams = RemoveHookTeamStore(inner: InMemoryPairedMacBackupTeamStore())
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-a" },
            pendingDeleteStore: pending,
            backupTeamStore: hookedTeams
        )
        // Pair the Mac through the seam: the mirror echo saves the mapping, so
        // the forget's tombstone routes CONCRETELY to team-a.
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        // During the flush's post-upload mapping cleanup: the Mac re-pairs
        // (clearing the sent record) and is immediately forgotten AGAIN — but
        // that second tombstone's own upload fails, so it must stay queued.
        await hookedTeams.setOnRemove { [store, backup] in
            try? await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try! Self.route("100.82.214.112")],
                instanceTag: nil,
                markActive: false,
                stackUserID: "user-1",
                teamID: nil,
                now: Date(timeIntervalSince1970: 2)
            )
            await backup.setFailNextUploads(99)
            try? await store.removeExactScope(
                macDeviceID: "mac-a",
                instanceTag: nil,
                stackUserID: "user-1",
                teamID: "team-a"
            )
        }
        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: "team-a"
        )

        // The second forget's tombstone was never delivered (its upload
        // failed), so it must still be queued for retry somewhere.
        var queued: [String] = []
        for scope in await pending.storedScopes() {
            for raw in await pending.load(scope: scope) where raw.contains("mac-a") {
                queued.append(raw)
            }
        }
        #expect(!queued.isEmpty)
    }

    /// A record CREATED AFTER the forget is a revival, not a stale copy. A
    /// parked intent is cleared only by a LOCAL re-pair; when ANOTHER device
    /// re-pairs the Mac, this phone's intent would otherwise treat the new
    /// server record as stale on every restore — deleting it again and again,
    /// making cross-device re-pairing impossible to persist. A snapshot record
    /// newer than the intent's own stamp must RETIRE the intent instead of
    /// feeding it.
    @Test func remoteRePairRetiresTheParkedTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The team-less row this phone forgets at t=1000s.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        // Team-shown's backup is EMPTY during the forget (nothing to match),
        // and later holds the record ANOTHER PHONE re-created at t=2000s.
        let backup = FakeBackup(recordsByTeam: ["team-shown": []])
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" },
            pendingDeleteStore: pending,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        #expect(await composite.forgetHiddenComputer(hidden))

        // Another phone re-pairs the Mac: the SERVER stamps the write at
        // t=2000s, after this phone's forget.
        await backup.seedRecord(
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 2_000_000,
                lastSeenAt: 2_000_000,
                isActive: false,
                serverUpdatedAtMs: 2_000_000
            ),
            teamID: "team-shown"
        )
        let deletesBefore = await backup.uploadedOps().filter {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }.count
        await store.refreshFromBackup(stackUserID: "user-1")

        // The revival retired the intent; no delete was sent against it.
        let deletesAfter = await backup.uploadedOps().filter {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }.count
        #expect(deletesAfter == deletesBefore)
        var survivingIntents: [String] = []
        for scope in await pending.storedScopes() {
            for raw in await pending.load(scope: scope) where raw.contains("mac-a") {
                survivingIntents.append(raw)
            }
        }
        #expect(survivingIntents.isEmpty)
    }

    /// The restore echo must track the RETAINED local row's scope. LWW can keep
    /// a NEWER team-less local row without re-stamping it into the restore's
    /// team; recording the mapping only under the restore team leaves the later
    /// forget — which looks the mapping up under the row's actual nil team —
    /// with no verified destination, so the tombstone merely parks and, with the
    /// network down, the server copy survives for other devices to restore.
    @Test func restoreEchoTracksTheRetainedTeamlessRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The local team-less row is NEWER than the backup copy, so the merge
        // retains it verbatim — team-less.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 9_000_000)
        )
        let backup = FakeBackup(recordsByTeam: [
            "team-a": [
                PairedMacBackupRecord(
                    macDeviceID: "mac-a",
                    displayName: "Desk Mac",
                    routes: [try Self.route("100.82.214.112")],
                    createdAt: 1_000,
                    lastSeenAt: 1_000,
                    isActive: false
                ),
            ],
        ])
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-a" }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        // The restore of team-a echoes that its backup holds the pairing; the
        // merge RETAINS the newer team-less local row.
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The network drops before the forget: only a ROUTED tombstone (via the
        // persisted echo) can deliver the delete.
        await backup.setFailNextFetches(99)

        #expect(await composite.forgetHiddenComputer(hidden))

        // The echo was recorded against the retained row's OWN (nil) scope, so
        // the forget routed the delete to team-a without needing the network
        // for another echo.
        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        var routedDelete = false
        for (index, batch) in await backup.uploadBatches().enumerated() {
            for op in batch {
                if case .delete(let macDeviceID) = op, macDeviceID == "mac-a",
                   teams.indices.contains(index), teams[index] == "team-a" {
                    routedDelete = true
                }
            }
        }
        #expect(routedDelete)
        _ = ops
    }

    /// A record recognized as a REVIVAL must also be RESTORED in the same
    /// merge, not merely spared its delete: the intent's suppression filtered
    /// it out before the classification ran, and the completed restore is
    /// memoized — so the re-paired Mac stayed missing locally for the rest of
    /// the launch even though its tombstone had just been retired.
    @Test func revivedRecordIsRestoredInTheSameMerge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        let backup = FakeBackup(recordsByTeam: ["team-shown": []])
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        #expect(await composite.forgetHiddenComputer(hidden))

        // Another phone re-pairs the Mac (server write well after the forget).
        await backup.seedRecord(
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 2_000_000,
                lastSeenAt: 2_000_000,
                isActive: false,
                serverUpdatedAtMs: 2_000_000
            ),
            teamID: "team-shown"
        )
        await store.refreshFromBackup(stackUserID: "user-1")

        // The revival is back LOCALLY after the very restore that recognized
        // it — not stranded until relaunch behind the completed-restore memo.
        let rows = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.contains { $0.macDeviceID == "mac-a" })
    }

    /// The revival signal must be SERVER-authored. `createdAt` is written by
    /// the client and preserved across re-pairs: another phone that kept its
    /// local row across this phone's forget re-uploads the record with the
    /// ORIGINAL createdAt, so a client-time comparison misclassifies the
    /// genuine revival as stale and deletes it on every restore.
    @Test func remoteReviveWithPreservedCreatedAtRetiresTheTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        let backup = FakeBackup(recordsByTeam: ["team-shown": []])
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" },
            pendingDeleteStore: pending,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        #expect(await composite.forgetHiddenComputer(hidden))

        // The OTHER phone kept its local row across this forget: its explicit
        // re-add re-uploads the ORIGINAL client createdAt (t=500s, before this
        // forget), while the SERVER stamps the write at t=2000s.
        await backup.seedRecord(
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 500_000,
                lastSeenAt: 2_000_000,
                isActive: false,
                serverUpdatedAtMs: 2_000_000
            ),
            teamID: "team-shown"
        )
        let deletesBefore = await backup.uploadedOps().filter {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }.count
        await store.refreshFromBackup(stackUserID: "user-1")

        let deletesAfter = await backup.uploadedOps().filter {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }.count
        #expect(deletesAfter == deletesBefore)
        var survivingIntents: [String] = []
        for scope in await pending.storedScopes() {
            for raw in await pending.load(scope: scope) where raw.contains("mac-a") {
                survivingIntents.append(raw)
            }
        }
        #expect(survivingIntents.isEmpty)
    }

    /// A restore snapshot's mappings must persist in ONE batched pass. The
    /// production mapping store rewrites its entire dictionary and ordering on
    /// every save, so per-record saves turn a large restore into quadratic
    /// UserDefaults work while the user-visible paired-Mac load awaits it.
    @Test func restoreEchoPersistsMappingsInOneBatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let teams = CountingTeamStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: FakeBackup(recordsByTeam: [
                "team-a": [
                    PairedMacBackupRecord(
                        macDeviceID: "mac-a",
                        displayName: "A",
                        routes: [try Self.route("10.0.0.1")],
                        createdAt: 1_000,
                        lastSeenAt: 1_000,
                        isActive: false
                    ),
                    PairedMacBackupRecord(
                        macDeviceID: "mac-b",
                        displayName: "B",
                        routes: [try Self.route("10.0.0.2")],
                        createdAt: 1_000,
                        lastSeenAt: 1_000,
                        isActive: false
                    ),
                    PairedMacBackupRecord(
                        macDeviceID: "mac-c",
                        displayName: "C",
                        routes: [try Self.route("10.0.0.3")],
                        createdAt: 1_000,
                        lastSeenAt: 1_000,
                        isActive: false
                    ),
                ],
            ]),
            teamIDProvider: { "team-a" },
            backupTeamStore: teams
        )

        _ = try await store.loadAll(stackUserID: "user-1", teamID: nil)

        // Three snapshot records, ONE persistence pass — not one full-state
        // rewrite per record.
        #expect(await teams.saveAllCalls == 1)
        #expect(await teams.individualSaveCalls == 0)
    }

    /// A record the server wrote BEFORE the forget is a stale copy, however
    /// recently: forgetting a currently-online Mac — whose backup was route-
    /// mirrored seconds earlier — is the COMMON case, and a skew allowance
    /// that accepts pre-forget writes as revivals would bypass the forget's
    /// suppression, retire the intent, and let the supposedly forgotten Mac
    /// restore instead of receiving its delete.
    @Test func recentPreForgetWriteIsStillSuppressedAndDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        // The Mac's backup was mirrored 30 SECONDS before the forget (server
        // write at t=970s; the forget stamps t=1000s). The FIRST fetch fails,
        // so no destination echo exists before the forget and the tombstone
        // PARKS — the path where suppression and revival classification decide
        // everything.
        let backup = FakeBackup(
            recordsByTeam: [
                "team-shown": [
                    PairedMacBackupRecord(
                        macDeviceID: "mac-a",
                        displayName: "Desk Mac",
                        routes: [try Self.route("100.82.214.112")],
                        createdAt: 900_000,
                        lastSeenAt: 970_000,
                        isActive: false,
                        serverUpdatedAtMs: 970_000
                    ),
                ],
            ],
            failNextFetches: 99
        )
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" },
            pendingDeleteStore: pending,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        // The forget PARKS its tombstone offline.
        #expect(await composite.forgetHiddenComputer(hidden))

        // The network returns; the next restore of team-shown sees the stale
        // pre-forget record.
        await backup.setFailNextFetches(0)
        await store.refreshFromBackup(stackUserID: "user-1")

        // The stale copy was DELETED from the backup (the echo flushed the
        // parked intent against it)...
        let deleteSent = await backup.uploadedOps().contains {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            default: return false
            }
        }
        #expect(deleteSent)
        // ...and the row was not resurrected locally.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// The forget boundary must keep MILLISECOND precision. Flooring the
    /// tombstone stamp to whole seconds while server write times carry
    /// milliseconds classifies a server write from the SAME second but before
    /// the forget (server 1000.5s, forget 1000.9s) as a post-forget revival:
    /// the intent retires and the stale record restores instead of being
    /// deleted.
    @Test func sameSecondPreForgetWriteIsNotARevival() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        // Server write at 1000.5s; the forget stamps 1000.9s — SAME second.
        let backup = FakeBackup(
            recordsByTeam: [
                "team-shown": [
                    PairedMacBackupRecord(
                        macDeviceID: "mac-a",
                        displayName: "Desk Mac",
                        routes: [try Self.route("100.82.214.112")],
                        createdAt: 900_000,
                        lastSeenAt: 1_000_500,
                        isActive: false,
                        serverUpdatedAtMs: 1_000_500
                    ),
                ],
            ],
            failNextFetches: 99
        )
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-shown" },
            pendingDeleteStore: pending,
            now: { Date(timeIntervalSince1970: 1_000.9) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-shown" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        #expect(await composite.forgetHiddenComputer(hidden))

        await backup.setFailNextFetches(0)
        await store.refreshFromBackup(stackUserID: "user-1")

        // The pre-forget record was deleted, not restored.
        let deleteSent = await backup.uploadedOps().contains {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            default: return false
            }
        }
        #expect(deleteSent)
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// One tagged instance's revival must not retire the DEVICE-WIDE
    /// tombstone: the wildcard forget revoked every tag's binding, and a stale
    /// tag that exists only in another team's backup still needs suppression
    /// and deletion. Per-record revival classification already lets the
    /// revived tag through; retiring the whole intent would let the OTHER
    /// tag's dead record restore.
    @Test func taggedRevivalKeepsTheDeviceWideTombstoneForOtherTags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 900)
        )
        // Team-shown holds a REVIVED tagged instance (server write after the
        // forget); team-other holds a STALE tagged record (server write before
        // the forget) the wildcard's device-wide intent must still delete.
        let backup = FakeBackup(
            recordsByTeam: [
                "team-shown": [
                    PairedMacBackupRecord(
                        macDeviceID: "mac-a",
                        displayName: "Desk Mac (alpha)",
                        routes: [try Self.route("100.82.214.112")],
                        createdAt: 900_000,
                        lastSeenAt: 2_000_000,
                        isActive: false,
                        instanceTag: "alpha",
                        serverUpdatedAtMs: 2_000_000
                    ),
                ],
                "team-other": [
                    PairedMacBackupRecord(
                        macDeviceID: "mac-a",
                        displayName: "Desk Mac (beta)",
                        routes: [try Self.route("100.82.214.113")],
                        createdAt: 500_000,
                        lastSeenAt: 500_000,
                        isActive: false,
                        instanceTag: "beta",
                        serverUpdatedAtMs: 500_000
                    ),
                ],
            ],
            failNextFetches: 99
        )
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let team = TeamBox()
        team.value = "team-shown"
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { team.value },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // Offline wildcard forget: the device-wide intent parks.
        #expect(await composite.forgetHiddenComputer(hidden))
        await backup.setFailNextFetches(0)

        // Team-shown's restore sees the alpha REVIVAL — the intent must not
        // retire wholesale.
        await store.refreshFromBackup(stackUserID: "user-1")
        // Team-other's later restore must still DELETE the stale beta record.
        team.value = "team-other"
        await store.refreshFromBackup(stackUserID: "user-1")

        let betaDeleted = await backup.uploadedOps().contains {
            switch $0 {
            case .deleteInstance(let macDeviceID, let instanceTag):
                return macDeviceID == "mac-a" && instanceTag == "beta"
            default: return false
            }
        }
        #expect(betaDeleted)
    }

    /// The account-wide parked record must preserve each row's LOCAL team so
    /// crash recovery can replay the exact delete offline. A record parked
    /// with a nil local team replays only against nil-team rows; if the app
    /// dies after parking but before the routed per-row intent lands, a
    /// concrete-team row survives every offline launch.
    @Test func parkedRecordReplaysAConcreteTeamRowOffline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A TEAM-A row whose local delete fails transiently (the crash-window
        // proxy: the parked record is durable, the local delete never landed).
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let failing = FailOnceStore(inner: base)
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: failing,
            backup: FakeBackup(failNextFetches: 99),
            teamIDProvider: { "team-a" },
            pendingDeleteStore: pending
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: store,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The forget FAILS on the local delete; the parked record survives.
        #expect(!(await composite.forgetHiddenComputer(hidden)))

        // The next OFFLINE read must finish the local delete from the outbox
        // alone — the parked record carries the row's exact team scope.
        _ = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}

/// Fails the FIRST exact-scope delete only, modeling the crash/transient
/// window between the durable outbox write and the local delete.
private final class FailOnceStore: MobilePairedMacStoring, @unchecked Sendable {
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {}

    struct TransientError: Error {}
    let inner: any MobilePairedMacStoring
    private let lock = NSLock()
    private var failed = false

    init(inner: any MobilePairedMacStoring) {
        self.inner = inner
    }

    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let shouldFail = lock.withLock {
            if failed { return false }
            failed = true
            return true
        }
        if shouldFail { throw TransientError() }
        try await inner.removeExactScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func loadAllInstances(macDeviceID: String, stackUserID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(macDeviceID: macDeviceID, stackUserID: stackUserID)
    }

    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

/// Counts save traffic so a test can assert batching.
private actor CountingTeamStore: PairedMacBackupTeamStoring {
    private let inner = InMemoryPairedMacBackupTeamStore()
    private(set) var individualSaveCalls = 0
    private(set) var saveAllCalls = 0

    func load(key: String) async -> String? { await inner.load(key: key) }

    func save(_ teamID: String, key: String) async {
        individualSaveCalls += 1
        await inner.save(teamID, key: key)
    }

    func saveAll(_ mappings: [PairedMacBackupTeamMapping]) async {
        saveAllCalls += 1
        for mapping in mappings {
            await inner.save(mapping.teamID, key: mapping.key)
        }
    }

    func remove(key: String) async { await inner.remove(key: key) }

    func removeAll() async { await inner.removeAll() }
}

/// Wraps a paired-Mac store and fires a one-shot hook while an exact-scope
/// delete is suspended in the inner store, so a test can interleave a
/// concurrent mutation deterministically.
private final class RemoveHookStore: MobilePairedMacStoring, @unchecked Sendable {
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {}

    let inner: any MobilePairedMacStoring
    private let lock = NSLock()
    private var hook: (@Sendable () async -> Void)?

    init(inner: any MobilePairedMacStoring) {
        self.inner = inner
    }

    func setOnRemoveExactScope(_ hook: @escaping @Sendable () async -> Void) async {
        lock.withLock { self.hook = hook }
    }

    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        if let hook = lock.withLock({ let h = hook; hook = nil; return h }) {
            await hook()
        }
        try await inner.removeExactScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func loadAllInstances(macDeviceID: String, stackUserID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(macDeviceID: macDeviceID, stackUserID: stackUserID)
    }

    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

/// Wraps a backup-team mapping store and fires a one-shot hook while a
/// mapping removal is suspended, so a test can interleave a concurrent
/// mutation deterministically.
private actor RemoveHookTeamStore: PairedMacBackupTeamStoring {
    private let inner: any PairedMacBackupTeamStoring
    private var hook: (@Sendable () async -> Void)?

    init(inner: any PairedMacBackupTeamStoring) {
        self.inner = inner
    }

    func setOnRemove(_ hook: @escaping @Sendable () async -> Void) {
        self.hook = hook
    }

    func load(key: String) async -> String? {
        await inner.load(key: key)
    }

    func save(_ teamID: String, key: String) async {
        await inner.save(teamID, key: key)
    }

    func remove(key: String) async {
        if let hook {
            self.hook = nil
            await hook()
        }
        await inner.remove(key: key)
    }

    func removeAll() async {
        await inner.removeAll()
    }
}
