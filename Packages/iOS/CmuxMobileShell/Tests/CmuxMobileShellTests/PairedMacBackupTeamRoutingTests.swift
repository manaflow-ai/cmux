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
/// A row's backup tombstone must route to the SAME team scope its backup was
/// uploaded under: the row's own stamped `team_id` (nil for a team-less row).
/// `upsert` resolves and stamps one team, then uploads the record under exactly
/// that team, so the row's own team is the only client-side value tied to where
/// the backup lives. The display team is NOT: a team-less row is visible under
/// every selected team (legacy visibility), so the team it happens to be shown
/// under when forgotten is arbitrary. Routing the tombstone there desynchronizes
/// the pending-delete outbox from the row's own scope — a restore under the
/// row's real (team-less) scope does not see the tombstone and can resurrect the
/// forgotten row — and can delete a same-device record from an unrelated team's
/// backup while the row's actual backup survives.
@MainActor
@Suite struct PairedMacBackupTeamRoutingTests {
    @Test func forgetRoutesBackupTombstoneToRowOwnTeamScopeNotDisplayTeam() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less local row, exactly as `upsert` stamps one when no team was
        // selected at pairing time. Its backup was uploaded under `teamID: nil`.
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

        // The backup tombstone must go out under the row's OWN team scope (nil,
        // matching its upload), NOT the team it was displayed under.
        let ops = await backup.uploadedOps()
        let teams = await backup.uploadTeams()
        let deleteIndex = try #require(ops.firstIndex {
            switch $0 {
            case .delete(let macDeviceID): return macDeviceID == "mac-a"
            case .deleteInstance(let macDeviceID, _): return macDeviceID == "mac-a"
            default: return false
            }
        })
        #expect(teams.indices.contains(deleteIndex))
        #expect(teams[deleteIndex] == nil)
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
