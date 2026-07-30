import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for the backup-team routing of an exact-scope forget.
///
/// Forgetting a team-less local row must delete the LOCAL row under its own
/// team-less key, but route the BACKUP tombstone to the team the row was shown
/// under (the captured display/backup team), not reuse the nil local team.
/// Paired-Mac backups live in a per-team Durable Object, so reusing nil lets the
/// server resolve the delete to whatever team is selected when it flushes; that
/// tombstone can then wipe a same-device record from the wrong team's backup.
/// `removeExactScope(...backupTeamID:)` separates the local-row scope from the
/// backup scope so the tombstone is routed deterministically.
@Suite struct PairedMacBackupTeamRoutingTests {
    @Test func exactScopeForgetRoutesBackupTombstoneToDisplayTeam() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A team-less local row.
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
        // The live selected team at flush time is "team-live"; the row was
        // DISPLAYED under "team-shown" when the user forgot it. The tombstone must
        // route to the captured display team, immune to the live-team drift, while
        // the local delete stays team-less.
        let store = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-live" }
        )

        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: nil,
            stackUserID: "user-1",
            teamID: nil,
            backupTeamID: "team-shown"
        )

        // Local row deleted under its own team-less key.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })

        // The backup tombstone routed to the captured display team, NOT nil and
        // NOT the live team.
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
        #expect(teams[deleteIndex] == "team-shown")
    }

    @Test func exactScopeBackupTeamSurvivesEveryProductionDecorator() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = FakeBackup()
        let backed = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-live" }
        )
        let scope = try #require(MobileIOSBuildScope("feature"))
        let buildScoped = IOSBuildScopedPairedMacStore(inner: backed, scope: scope)
        let compatible = MobileMacBuildCompatibilityPolicy
            .development(expectedInstanceTag: "feature")
            .scoping(buildScoped)
        let store = TeamScopedPairedMacStore(
            inner: compatible,
            teamIDProvider: { "team-live" }
        )

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.removeExactScope(
            macDeviceID: "mac-a",
            instanceTag: "feature",
            stackUserID: "user-1",
            teamID: nil,
            backupTeamID: "team-shown"
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
        #expect(teams[deleteIndex] == "team-shown")
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
