import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Team management through the coordinator: delete and rename change the
/// membership list the whole app reads, and deleting the active team moves
/// every team-scoped feature to a team that still exists.
@MainActor
@Suite("Auth coordinator team management")
struct AuthCoordinatorTeamManagementTests {
    private func signedIn(teams: [CMUXAuthTeam], selected: String) async throws -> (AuthCoordinator, FakeAuthClient) {
        let client = FakeAuthClient(user: CMUXAuthUser(id: "user", primaryEmail: "user@example.com", displayName: "User"))
        await client.setTeams(teams)
        await client.setServerSelectedTeamID(selected)
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: AuthTimeouts(interactiveFlow: .seconds(1), network: .seconds(60))
        )
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")
        #expect(coordinator.resolvedTeamID == selected)
        return (coordinator, client)
    }

    private let alpha = CMUXAuthTeam(id: "team-a", displayName: "Alpha")
    private let beta = CMUXAuthTeam(id: "team-b", displayName: "Beta")

    @Test func deletingTheActiveTeamFallsBackToAnotherAndSavesIt() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha, beta], selected: "team-a")

        try await coordinator.deleteTeam(id: "team-a")

        #expect(coordinator.availableTeams.map(\.id) == ["team-b"])
        #expect(coordinator.resolvedTeamID == "team-b")
        #expect(await client.lastSelectedTeamID == "team-b")
    }

    @Test func deletingAnotherTeamKeepsTheActiveOne() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha, beta], selected: "team-a")
        let selections = await client.teamSelectionCount

        try await coordinator.deleteTeam(id: "team-b")

        #expect(coordinator.availableTeams.map(\.id) == ["team-a"])
        #expect(coordinator.resolvedTeamID == "team-a")
        #expect(await client.teamSelectionCount == selections)
    }

    @Test func aDeleteBillingRefusesLeavesTheTeamListed() async throws {
        let billed = CMUXAuthTeam(id: FakeAuthClient.billedTeamID, displayName: "Billed")
        let (coordinator, _) = try await signedIn(teams: [billed, alpha], selected: billed.id)

        await #expect(throws: CMUXTeamError.subscriptionActive) {
            try await coordinator.deleteTeam(id: billed.id)
        }

        #expect(coordinator.availableTeams.map(\.id) == [billed.id, "team-a"])
        #expect(coordinator.resolvedTeamID == billed.id)
    }

    @Test func renamingShowsTheTrimmedNameEverywhere() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha, beta], selected: "team-a")

        let renamed = try await coordinator.renameTeam(id: "team-b", displayName: "  Research  ")

        #expect(renamed.displayName == "Research")
        #expect(coordinator.availableTeams.first { $0.id == "team-b" }?.displayName == "Research")
        #expect(await client.teams.first { $0.id == "team-b" }?.displayName == "Research")
    }

    @Test func anInvalidNameIsRefusedBeforeAnyRequest() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha], selected: "team-a")

        await #expect(throws: CMUXTeamError.invalidName) {
            try await coordinator.renameTeam(id: "team-a", displayName: "   ")
        }
        await #expect(throws: CMUXTeamError.invalidName) {
            try await coordinator.renameTeam(id: "team-a", displayName: String(repeating: "x", count: CMUXTeamName.maximumLength + 1))
        }
        #expect(await client.teams.first?.displayName == "Alpha")
    }

    /// A team-list read that started before a delete answers with the team in
    /// it; landing after the delete, it must not bring the team back.
    @Test func aReadInFlightDoesNotBringADeletedTeamBack() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha, beta], selected: "team-a")
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextSelectedTeamRead(started: started, release: release)

        let refresh = Task { await coordinator.refreshTeams() }
        await started.waitUntilStarted()
        try await coordinator.deleteTeam(id: "team-b")
        await release.release()
        await refresh.value

        #expect(coordinator.availableTeams.map(\.id) == ["team-a"])
    }

    /// No switch starts while a delete runs, so the delete's fallback is the
    /// team cmux ends in.
    @Test func aSwitchDuringADeleteIsRefused() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha, beta], selected: "team-a")
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamDelete(started: started, release: release)

        let delete = Task { try await coordinator.deleteTeam(id: "team-a") }
        await started.waitUntilStarted()
        #expect(coordinator.isDeletingTeam)
        await #expect(throws: AuthTeamChangeInProgressError.self) { try await coordinator.selectTeam(id: "team-a") }
        await release.release()
        try await delete.value

        #expect(!coordinator.isDeletingTeam)
        #expect(coordinator.resolvedTeamID == "team-b")
        #expect(await client.lastSelectedTeamID == "team-b")
    }

    @Test func membershipsCarryRoles() async throws {
        let (coordinator, _) = try await signedIn(teams: [alpha, beta], selected: "team-a")

        let memberships = try await coordinator.teamMemberships()

        #expect(memberships.teams.map(\.role) == [.admin, .member])
        #expect(memberships.rolesKnown)
        #expect(memberships.teams.first?.canDelete == true)
        #expect(memberships.teams.last?.canRename == false)
    }

    /// Accepting an invitation addressed to the user puts the joined team in the list the whole
    /// app reads and makes it active, so its Cloud machines are the ones cmux shows next.
    @Test func acceptingAnInvitationJoinsAndActivatesTheTeam() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha], selected: "team-a")
        await client.setReceivedInvitations(["inv-1": beta])

        let received = try await coordinator.receivedTeamInvitations()
        #expect(received.map(\.teamName) == ["Beta"])

        let joined = try await coordinator.acceptTeamInvitation(id: "inv-1")

        #expect(joined.teamID == "team-b")
        #expect(coordinator.availableTeams.map(\.id) == ["team-a", "team-b"])
        #expect(coordinator.resolvedTeamID == "team-b")
        #expect(try await coordinator.receivedTeamInvitations().isEmpty)
    }

    /// A team-list read that starts while the accept runs answers without the joined team; it
    /// must not land over the accept's own re-read and drop the team it joined.
    @Test func aTeamReadDuringTheAcceptCannotDropTheJoinedTeam() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha], selected: "team-a")
        await client.setReceivedInvitations(["inv-1": beta])
        let acceptStarted = TestPhaseSignal()
        let acceptRelease = TestContinuationBlocker()
        await client.holdNextTeamAccept(started: acceptStarted, release: acceptRelease)

        let accept = Task { try await coordinator.acceptTeamInvitation(id: "inv-1") }
        await acceptStarted.waitUntilStarted()
        let listStarted = TestPhaseSignal()
        let listRelease = TestContinuationBlocker()
        await client.holdNextTeamList(started: listStarted, release: listRelease)
        let refresh = Task { await coordinator.refreshTeams() }
        await listStarted.waitUntilStarted()
        await acceptRelease.release()
        let joined = try await accept.value
        await listRelease.release()
        await refresh.value

        #expect(joined.teamID == "team-b")
        #expect(coordinator.availableTeams.map(\.id) == ["team-a", "team-b"])
        #expect(coordinator.resolvedTeamID == "team-b")
    }

    @Test func decliningLeavesTheMembershipAlone() async throws {
        let (coordinator, client) = try await signedIn(teams: [alpha], selected: "team-a")
        await client.setReceivedInvitations(["inv-1": beta])

        try await coordinator.declineTeamInvitation(id: "inv-1")

        #expect(coordinator.availableTeams.map(\.id) == ["team-a"])
        #expect(coordinator.resolvedTeamID == "team-a")
        await #expect(throws: CMUXTeamError.invitationInvalid) {
            try await coordinator.acceptTeamInvitation(id: "inv-1")
        }
    }
}

/// The fake answers like the cmux team API: the first team is the user's as
/// admin, the others as member; ``billedTeamID`` has a subscription.
extension FakeAuthClient: TeamManaging {
    static let billedTeamID = "team-billed"

    func teamMemberships() async throws -> CMUXTeamMemberships {
        let admin = CMUXTeamPermissions(updateTeam: true, deleteTeam: true, inviteMembers: true, readMembers: true, removeMembers: true)
        return CMUXTeamMemberships(
            teams: teams.enumerated().map { index, team in
                CMUXTeamMembership(id: team.id, displayName: team.displayName, role: index == 0 ? .admin : .member,
                                   permissions: index == 0 ? admin : CMUXTeamPermissions(readMembers: true))
            },
            selectedTeamID: serverSelectedTeamID)
    }

    func teamDetail(id: String) async throws -> CMUXTeamDetail {
        guard let team = teams.first(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        return CMUXTeamDetail(team: .init(id: team.id, displayName: team.displayName),
                              viewer: .init(userId: "user", role: .admin, permissions: CMUXTeamPermissions()),
                              members: [], invitations: [], billing: nil)
    }

    func renameTeam(id: String, displayName: String) async throws -> CMUXAuthTeam {
        guard let index = teams.firstIndex(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        teams[index] = CMUXAuthTeam(id: id, displayName: displayName)
        return teams[index]
    }

    func deleteTeam(id: String) async throws {
        if let gate = takeTeamDeleteGate() {
            await gate.started.markStarted()
            await gate.release.wait()
        }
        if id == Self.billedTeamID { throw CMUXTeamError.subscriptionActive }
        guard teams.contains(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        teams.removeAll { $0.id == id }
        if serverSelectedTeamID == id { serverSelectedTeamID = nil }
    }

    func inviteToTeam(id: String, emails: [String], role: CMUXTeamRole) async throws -> CMUXTeamInviteResult {
        guard teams.contains(where: { $0.id == id }) else { throw CMUXTeamError.notFound }
        return CMUXTeamInviteResult(invitations: emails.enumerated().map { .init(id: "i\($0.offset)", email: $0.element, role: role, expiresAt: "") },
                                    failed: [])
    }

    func receivedTeamInvitations() async throws -> [CMUXReceivedTeamInvitation] {
        receivedInvitations.sorted { $0.key < $1.key }.map { id, team in
            CMUXReceivedTeamInvitation(id: id, teamID: team.id, teamName: team.displayName, email: "user@example.com",
                                       role: .member, invitedBy: "Sam", expiresAt: "")
        }
    }

    /// Joins like the server: the user becomes a member and the team the account's selection.
    func acceptTeamInvitation(id: String) async throws -> CMUXTeamJoin {
        if let gate = takeTeamAcceptGate() {
            await gate.started.markStarted()
            await gate.release.wait()
        }
        guard let team = receivedInvitations.removeValue(forKey: id) else { throw CMUXTeamError.invitationInvalid }
        if !teams.contains(where: { $0.id == team.id }) { teams.append(team) }
        serverSelectedTeamID = team.id
        return CMUXTeamJoin(teamID: team.id, role: .member)
    }

    func declineTeamInvitation(id: String) async throws {
        guard receivedInvitations.removeValue(forKey: id) != nil else { throw CMUXTeamError.invitationInvalid }
    }
}
