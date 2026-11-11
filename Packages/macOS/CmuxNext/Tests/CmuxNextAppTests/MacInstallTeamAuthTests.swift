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

    /// A refused team mint tells the app which team, so it re-reads the account's teams (a team deleted on
    /// the web stayed selected, Leo 2026-11-10); a minted team tells it nothing.
    @Test func aRefusedTeamMintNamesTheTeamToTheApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), refused = RefusedTeams()
        let identity = MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac",
                                          clientVersion: "2.4.0", teamRefused: { refused.add($0) })
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        _ = try await identity.installToken(team: team)
        #expect(refused.teams.isEmpty)
        await owner.deny(team)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await identity.installToken(team: team) }
        #expect(refused.teams == [team])
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

private final class RefusedTeams: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var teams: [String] { lock.withLock { list } }
    func add(_ team: String) { lock.withLock { list.append(team) } }
}
