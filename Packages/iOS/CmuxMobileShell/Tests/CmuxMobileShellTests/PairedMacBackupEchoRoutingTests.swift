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

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
