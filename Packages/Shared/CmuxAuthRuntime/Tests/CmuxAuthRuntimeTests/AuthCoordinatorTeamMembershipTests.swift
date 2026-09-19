import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Behavior of the team list the picker drives: creating a team, refreshing
/// membership changed elsewhere, and the guards that keep one account's teams
/// off another account's session.
@MainActor
@Suite struct AuthCoordinatorTeamMembershipTests {
    private func makeCoordinator(
        client: FakeAuthClient
    ) -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        return (coordinator, store)
    }

    private func signedIn(
        teams: [CMUXAuthTeam]
    ) async throws -> (AuthCoordinator, FakeAuthClient, FakeKeyValueStore) {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams(teams)
        let (coordinator, store) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        return (coordinator, client, store)
    }

    @Test func creatingATeamMakesItActiveAndPersistsTheSelection() async throws {
        let (coordinator, client, store) = try await signedIn(
            teams: [CMUXAuthTeam(id: "team_a", displayName: "Alpha")]
        )

        let created = try await coordinator.createTeam(displayName: "Beta")

        #expect(await client.createdTeamNames == ["Beta"])
        #expect(coordinator.availableTeams.contains { $0.id == created.id })
        #expect(coordinator.selectedTeamID == created.id)
        #expect(coordinator.resolvedTeamID == created.id)
        #expect(store.string(forKey: "selected_team") == created.id)
    }

    @Test func creatingATeamTrimsItsName() async throws {
        let (coordinator, client, _) = try await signedIn(teams: [])

        _ = try await coordinator.createTeam(displayName: "  Beta \n")

        #expect(await client.createdTeamNames == ["Beta"])
    }

    @Test func aBlankTeamNameIsRejectedWithoutARoundTrip() async throws {
        let (coordinator, client, _) = try await signedIn(teams: [])

        await #expect(throws: AuthError.invalidTeamName) {
            try await coordinator.createTeam(displayName: "   ")
        }
        #expect(await client.createdTeamNames.isEmpty)
    }

    @Test func aSignedOutCoordinatorCannotCreateATeam() async {
        let client = FakeAuthClient()
        let (coordinator, _) = makeCoordinator(client: client)

        await #expect(throws: AuthError.unauthorized) {
            try await coordinator.createTeam(displayName: "Beta")
        }
        #expect(await client.createdTeamNames.isEmpty)
        #expect(coordinator.availableTeams.isEmpty)
    }

    @Test func aCreatedTeamStillAppearsWhenTheFollowUpListReadFails() async throws {
        // The create succeeded, so the team exists and the user is its member.
        // A failed or lagging list read must not hide it from the picker.
        let (coordinator, client, _) = try await signedIn(
            teams: [CMUXAuthTeam(id: "team_a", displayName: "Alpha")]
        )
        await client.setCreateTeamAppendsToList(false)
        await client.setThrowOnListTeams(AuthError.networkError)

        let created = try await coordinator.createTeam(displayName: "Beta")

        #expect(coordinator.availableTeams.contains { $0.id == created.id })
        #expect(coordinator.selectedTeamID == created.id)
    }

    @Test func refreshPicksUpATeamAddedElsewhere() async throws {
        let (coordinator, client, _) = try await signedIn(
            teams: [CMUXAuthTeam(id: "team_a", displayName: "Alpha")]
        )

        await client.setTeams([
            CMUXAuthTeam(id: "team_a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team_b", displayName: "Beta"),
        ])
        await coordinator.refreshAvailableTeams()

        #expect(coordinator.availableTeams.map(\.id) == ["team_a", "team_b"])
    }

    @Test func refreshMovesOffATeamTheUserWasRemovedFrom() async throws {
        let (coordinator, client, store) = try await signedIn(teams: [
            CMUXAuthTeam(id: "team_a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team_b", displayName: "Beta"),
        ])
        coordinator.selectedTeamID = "team_b"

        await client.setTeams([CMUXAuthTeam(id: "team_a", displayName: "Alpha")])
        await coordinator.refreshAvailableTeams()

        #expect(coordinator.availableTeams.map(\.id) == ["team_a"])
        #expect(coordinator.selectedTeamID == "team_a")
        #expect(store.string(forKey: "selected_team") == "team_a")
    }

    @Test func refreshFailureKeepsTheTeamsAlreadyKnown() async throws {
        let (coordinator, client, _) = try await signedIn(
            teams: [CMUXAuthTeam(id: "team_a", displayName: "Alpha")]
        )

        await client.setThrowOnListTeams(AuthError.networkError)
        await coordinator.refreshAvailableTeams()

        #expect(coordinator.availableTeams.map(\.id) == ["team_a"])
    }

    @Test func signOutDuringCreateKeepsTheTeamOffTheSignedOutSession() async throws {
        let (coordinator, client, _) = try await signedIn(teams: [])
        await client.setThrowOnListTeams(AuthError.networkError)

        // Sign out lands while the create round trip is still in flight.
        async let create: CMUXAuthTeam = coordinator.createTeam(displayName: "Beta")
        await coordinator.signOut()
        _ = try? await create

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.availableTeams.isEmpty)
        #expect(coordinator.selectedTeamID == nil)
    }
}
