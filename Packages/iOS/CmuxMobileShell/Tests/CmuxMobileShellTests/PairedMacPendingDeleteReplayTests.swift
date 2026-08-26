import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for how the pending-delete outbox REPLAYS a tombstone.
///
/// A forget writes its tombstone (`addPendingDelete`) under a scope key that
/// pins the exact (account, team) of the deleted row, then deletes the local
/// row, then uploads the backup delete. If that upload fails (or the app dies),
/// the next read replays the tombstone. The replay's only job is to finish and
/// confirm THAT exact deletion; it must never broaden. Replaying through the
/// broad `remove` re-resolves visibility (``TeamScopedPairedMacStore`` looks the
/// device up under the scope's team, which also returns team-less legacy rows),
/// so in the common failed-upload case — where the exact row is ALREADY deleted
/// locally — the replay resolves a SURVIVING unrelated alias of the same device
/// and deletes it. Exact-scope replay is a no-op on the already-deleted row.
@Suite struct PairedMacPendingDeleteReplayTests {
    @Test func failedUploadReplayDoesNotDeleteSurvivingTeamlessSibling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Same device paired twice: the team row being forgotten, and an
        // unrelated team-less pairing that must survive. Team row first so the
        // team-less upsert does not get claimed into the team (see
        // MobileShellCompositeForgetTeamlessScopeTests for the ordering rule).
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Team Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Teamless Mac",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        // First upload (the forget's tombstone flush) fails, so the tombstone
        // stays in the outbox and the next read replays it.
        let backup = FakeBackup(failNextUploads: 1)
        let store = BackingUpPairedMacStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { "team-a" }),
            backup: backup,
            teamIDProvider: { "team-a" }
        )

        // The forget: exact-scope delete of the team row. Local delete succeeds,
        // backup upload fails, tombstone persists.
        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: "team-a"
        )
        let afterForget = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!afterForget.contains { $0.macDeviceID == "mac-a" && $0.teamID == "team-a" })
        #expect(afterForget.contains { $0.macDeviceID == "mac-a" && $0.teamID == nil })

        // The next read replays the pending tombstone (and retries the upload).
        _ = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")

        // The replay must be a no-op locally: its exact row is already gone.
        // The surviving team-less pairing of the same device must NOT be
        // collateral of the replay.
        let afterReplay = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(afterReplay.contains { $0.macDeviceID == "mac-a" && $0.teamID == nil })

        // The retried flush must still deliver the backup tombstone, scoped to
        // the team the tombstone was written under.
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
        #expect(teams[deleteIndex] == "team-a")
    }

    /// Crash recovery for a PARKED (account-wide) tombstone must be
    /// network-independent: if the app died between writing the parked intent
    /// and deleting the local row, the next read must finish that local delete
    /// from the outbox alone. Waiting for the restore to suppress it needs a
    /// successful backup fetch, so an offline launch would keep showing the
    /// supposedly forgotten computer.
    @MainActor
    @Test func parkedTombstoneReplaysItsLocalDeleteWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less row shown under the selected team (legacy visibility).
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
        // Every backup fetch fails: the launch is OFFLINE, so the restore's
        // suppression list can never run. Only the local outbox replay can
        // finish the delete.
        let backup = FakeBackup(failNextFetches: 99)
        let store = BackingUpPairedMacStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { "team-a" }),
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
        await composite.loadPairedMacs()
        await composite.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(composite.hiddenComputers.first { $0.macDeviceID == "mac-a" })
        // The forget parks the account-wide intent and deletes the row.
        #expect(await composite.forgetHiddenComputer(hidden))

        // Crash proxy: the parked intent was persisted but the local delete
        // never landed — re-create the row BELOW the backup seam so no revive
        // clears the intent.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )

        // The next read (still offline) must replay the parked local delete.
        _ = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// The parked account-wide tombstone set must stay BOUNDED. Intents retire
    /// only on revive, so without a cap every forget grows the persisted set
    /// forever — unbounded UserDefaults size and per-restore scan work.
    @Test func parkedTombstoneRetentionIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let pending = InMemoryPairedMacPendingDeleteStore()
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: FakeBackup(),
            teamIDProvider: { nil },
            pendingDeleteStore: pending
        )
        // Far more forgotten pairings than any account realistically holds,
        // in two batches so eviction applies across inserts.
        for batch in 0..<2 {
            let scopes = (0..<160).map { index in
                MobilePairedMacExactScope(
                    macDeviceID: "mac-\(batch)-\(index)",
                    instanceTag: nil,
                    stackUserID: "user-1",
                    teamID: nil
                )
            }
            try await store.removeExactScopes(scopes)
        }
        var maxScopeSize = 0
        for scope in await pending.storedScopes() {
            maxScopeSize = max(maxScopeSize, await pending.load(scope: scope).count)
        }
        #expect(maxScopeSize <= 256)
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}

