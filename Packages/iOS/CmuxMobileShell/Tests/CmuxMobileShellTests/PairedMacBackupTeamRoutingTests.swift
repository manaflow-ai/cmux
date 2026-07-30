import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A forget capability that succeeds without side effects, so the test reaches
/// the local-row + backup-tombstone cleanup that follows the revoke.
@MainActor
private final class BackupRoutingForget: MobileIrohMacForgetting {
    func forgetComputer(
        macDeviceID _: String,
        instanceTag _: String?,
        expectedAccountID _: String
    ) async throws {}
}

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
            personalIrohForget: BackupRoutingForget(),
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
            personalIrohForget: BackupRoutingForget(),
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

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
