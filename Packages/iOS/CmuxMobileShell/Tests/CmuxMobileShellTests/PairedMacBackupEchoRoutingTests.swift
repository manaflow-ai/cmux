import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for routing a delete tombstone to the team the server
/// REPORTED storing the record under.
///
/// A team-less row uploads with `teamID: nil`, and the SERVER resolves which
/// per-team Durable Object stores it (selected team, else sole team, else the
/// personal scope). That resolution is not derivable client-side, and it can
/// drift between the upload and a later forget: re-resolving `nil` at delete
/// time can send the tombstone to a DIFFERENT team's backup, where it deletes
/// nothing (the forgotten Mac later restores) or deletes an unrelated
/// same-device record. The presence worker echoes its verified resolved team on
/// every upload; the client must persist that echo per record and route the
/// record's tombstone to the echoed team.
@Suite struct PairedMacBackupEchoRoutingTests {
    @Test func tombstoneRoutesToTheTeamTheUploadWasStoredUnder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = FakeBackup()
        // The server reports storing this user's nil-team uploads under the
        // personal scope, the resolution it applies when no team is selected.
        await backup.setEchoedResolvedTeamID("team-personal")
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { nil }
        )
        // Pair a team-less Mac THROUGH the backing-up store, so its record is
        // uploaded (with teamID nil) and the server echo is observed.
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

        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: nil
        )

        // Local row deleted under its own team-less key.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })

        // The tombstone must go to the team the server SAID it stored the
        // record under, not re-resolve nil at delete time.
        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        let deleteIndex = try #require(ops.lastIndex {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            case .deleteInstance(let macDeviceID, _): return macDeviceID == "mac-a"
            default: return false
            }
        })
        #expect(teams.indices.contains(deleteIndex))
        #expect(teams[deleteIndex] == "team-personal")
    }

    /// The reinstall path: the row arrives via RESTORE (the mapping store is
    /// empty — a reinstall wiped it), not via a local upload. The restore
    /// snapshot's echoed team is the only statement of where those records'
    /// backups live, so it must be persisted per restored pairing; otherwise a
    /// later forget falls back to re-resolving nil and the wrong-backup
    /// deletion this coverage exists for comes back for exactly the restored
    /// rows.
    @Test func restoredRowsForgottenLaterRouteTombstonesToTheEchoedTeam() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The backup already holds a record for this user (paired before the
        // reinstall); the fetch reports the collection was read from the
        // server-resolved personal scope.
        let backup = FakeBackup(records: [
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 1_000,
                lastSeenAt: 2_000,
                isActive: false
            ),
        ])
        await backup.setEchoedResolvedTeamID("team-personal")
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { nil }
        )
        // The first read restores the backed-up row into the empty local store.
        let restored = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(restored.contains { $0.macDeviceID == "mac-a" })

        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: nil
        )

        // The tombstone must go to the team the restore snapshot was read
        // from, not re-resolve nil at delete time.
        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        let deleteIndex = try #require(ops.lastIndex {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            case .deleteInstance(let macDeviceID, _): return macDeviceID == "mac-a"
            default: return false
            }
        })
        #expect(teams.indices.contains(deleteIndex))
        #expect(teams[deleteIndex] == "team-personal")
    }

    /// The local store deliberately allows the SAME (account, device, tag)
    /// pairing to exist under several team scopes, and each team's copy lives
    /// in its own backup destination. The persisted echo must therefore be
    /// keyed by the ROW's team as well: without it, team B's upload overwrites
    /// team A's destination and A's later tombstone routes into B's backup —
    /// deleting the unrelated team-B record while A's survives to resurrect.
    @Test func perTeamCopiesKeepIndependentBackupDestinations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = FakeBackup()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { nil }
        )
        // The same device paired under two teams; each upload is stored under a
        // different server-reported destination.
        await backup.setEchoedResolvedTeamID("do-team-a")
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        await backup.setEchoedResolvedTeamID("do-team-b")
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 2)
        )

        // Forget team A's copy. Its tombstone must go to A's OWN destination —
        // not the one B's later upload reported.
        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: "team-a"
        )

        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        let deleteIndex = try #require(ops.lastIndex {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            case .deleteInstance(let macDeviceID, _): return macDeviceID == "mac-a"
            default: return false
            }
        })
        #expect(teams.indices.contains(deleteIndex))
        #expect(teams[deleteIndex] == "do-team-a")
    }

    /// A pending tombstone must be visible to restores of its DESTINATION
    /// scope: while its upload is still pending, a restore of the team that
    /// actually holds the record must both suppress the record (no resurrect)
    /// and retry the flush. Keying the intent by the row's LOCAL scope instead
    /// left a team-less row's tombstone under the nil-team scope, where a
    /// team-A restore never saw it — so the forgotten Mac came straight back on
    /// the next team-A restore, and the retry never ran.
    @Test func pendingTombstoneSuppressesRestoreOfItsDestinationScope() async throws {
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
        // The record still lives server-side (its delete has not landed yet).
        let backup = FakeBackup(records: [
            PairedMacBackupRecord(
                macDeviceID: "mac-a",
                displayName: "Desk Mac",
                routes: [try Self.route("100.82.214.112")],
                createdAt: 1_000,
                lastSeenAt: 2_000,
                isActive: false
            ),
        ])
        await backup.setEchoedResolvedTeamID("team-a")
        let team = TeamBox()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { team.value }
        )
        // Pair team-less; the upload's echo records that the backup actually
        // lives in team-a.
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
        // The forget's flush fails, and so does the first destination retry:
        // the tombstone stays pending across both.
        await backup.setFailNextUploads(2)
        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: nil
        )

        // The user now works in team-a — the team whose backup holds the
        // record. Its restore must NOT bring the forgotten Mac back.
        team.value = "team-a"
        let restored = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!restored.contains { $0.macDeviceID == "mac-a" })

        // And a later read under the destination retries the flush.
        _ = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        let deleteBatchIndex = (await backup.uploadBatches()).lastIndex { batch in
            batch.contains {
                switch $0 {
                case .delete(let id), .deleteInstance(let id, _): return id == "mac-a"
                default: return false
                }
            }
        }
        let teams = await backup.uploadTeams()
        #expect(deleteBatchIndex != nil)
        if let deleteBatchIndex {
            #expect(teams[deleteBatchIndex] == "team-a")
        }
    }

    /// Reviving ONE team's row must clear only THAT row's pending tombstone.
    /// The destination-keyed outbox can hold records with the same pairing id
    /// for different local teams (the same pairing forgotten in team A and
    /// team B, both backups in one destination); re-adding A's row must not
    /// cancel B's still-pending deletion, or B's forgotten record survives in
    /// the backup and restores later.
    @Test func revivingOneTeamsRowKeepsAnotherTeamsPendingTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let backup = FakeBackup()
        // Both teams' copies live in ONE destination collection.
        await backup.setEchoedResolvedTeamID("do-x")
        let team = TeamBox()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { team.value }
        )
        for team in ["team-a", "team-b"] {
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac (\(team))",
                routes: [try Self.route("100.82.214.112")],
                instanceTag: nil,
                markActive: false,
                stackUserID: "user-1",
                teamID: team,
                now: Date(timeIntervalSince1970: 1)
            )
        }
        // Forget BOTH rows; both tombstone flushes fail, leaving two pending
        // records (same pairing, different local teams) under do-x.
        await backup.setFailNextUploads(2)
        for team in ["team-a", "team-b"] {
            try await store.removeExactScope(
                macDeviceID: "mac-a",
                instanceTag: nil,
                stackUserID: "user-1",
                teamID: team
            )
        }

        // The user re-pairs the Mac in team A. Only team A's tombstone may be
        // cancelled by the revive.
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team-a again)",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )
        let batchesBeforeFlush = (await backup.uploadBatches()).count

        // A read under the destination retries the flush: team B's tombstone
        // must still be pending and go out now.
        team.value = "do-x"
        _ = try await store.loadAll(stackUserID: "user-1", teamID: nil)

        let newBatches = (await backup.uploadBatches()).dropFirst(batchesBeforeFlush)
        let deleteStillFlushed = newBatches.contains { batch in
            batch.contains {
                switch $0 {
                case .delete(let id), .deleteInstance(let id, _): return id == "mac-a"
                default: return false
                }
            }
        }
        #expect(deleteStillFlushed)
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
