import CmuxInstallAuthCore
import CmuxNextCloud
import Foundation
import Testing

@Suite struct MacInstallTeamAuthTests {
    private let team = "team_" + String(repeating: "a", count: 20)

    private func make(_ owner: MacTeamAuthOwner, root: URL) -> MacInstallIdentity {
        MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
    }

    @Test func teamTokensReuseTheActualMacSignerAndKeepThePersonalToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let personal = try await identity.installToken(), install = await identity.installID()
        let scoped = try await identity.installToken(team: team)
        #expect(scoped != personal)
        #expect(try await identity.installToken() == personal)
        #expect(await identity.installID() == install)
        #expect(await owner.registrations == 1)
        #expect(await owner.requestedTeams == [team])
        #expect(await owner.grants.allSatisfy { !$0.contains("execute") })
    }

    @Test func deniedTeamsPreserveTheMacKeyAndRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let install = await identity.installID()
        await owner.deny(team)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await identity.installToken(team: team) }
        await identity.invalidate()
        _ = try await identity.installToken() // Signature still verifies against the original registered public key.
        #expect(await identity.installID() == install)
        #expect(await owner.registrations == 1)
    }

    @Test func unbindingDuringATeamMintNeverReturnsTheOldUsersToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        await owner.holdNextTeamToken()
        let request = Task { try await identity.installToken(team: team) }
        defer { request.cancel(); Task { await owner.release() } }
        await owner.waitUntilHeld()
        await identity.unbind()
        await owner.release()
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await request.value }
        #expect(await identity.installID() == nil)
    }

    /// Review of the GitHub App lender at 9ea8b17: a cancelled team mint went on, because the
    /// client ran it in a task of its own, so superseded lends piled up requests.
    @Test func cancellingATeamMintReachesItsRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        await owner.holdNextTeamToken()
        let request = Task { try await identity.installToken(team: team) }
        await owner.waitUntilHeld()
        request.cancel()
        await owner.release()
        _ = try? await request.value
        #expect(await owner.cancelledAtToken == true)
    }
}
