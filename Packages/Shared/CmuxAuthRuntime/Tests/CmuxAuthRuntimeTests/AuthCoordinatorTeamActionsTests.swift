import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite("Auth coordinator team actions")
struct AuthCoordinatorTeamActionsTests {
    private func makeCoordinator(client: FakeAuthClient, launch: AuthLaunchOptions = .plain()) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: launch
        )
    }

    @Test func selectingTeamPersistsServerAndPublishesScope() async throws {
        let user = CMUXAuthUser(id: "user", primaryEmail: "user@example.com", displayName: "User")
        let client = FakeAuthClient(user: user)
        await client.setTeams([
            CMUXAuthTeam(id: "team-a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team-b", displayName: "Beta")
        ])
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")

        try await coordinator.selectTeam(id: "team-b")

        #expect(coordinator.resolvedTeamID == "team-b")
        #expect(await client.lastSelectedTeamID == "team-b")
    }

    @Test func creatingTeamAddsAndSelectsAuthoritativeTeam() async throws {
        let user = CMUXAuthUser(id: "user", primaryEmail: "user@example.com", displayName: "User")
        let client = FakeAuthClient(user: user)
        await client.setTeams([CMUXAuthTeam(id: "team-a", displayName: "Alpha")])
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")

        let created = try await coordinator.createTeam(displayName: "Shared Cloud")

        #expect(created.displayName == "Shared Cloud")
        #expect(coordinator.resolvedTeamID == created.id)
        #expect(coordinator.availableTeams.contains(created))
        #expect(await client.lastSelectedTeamID == created.id)
    }

    @Test func selectingUnknownTeamDoesNotChangeScope() async throws {
        let user = CMUXAuthUser(id: "user", primaryEmail: "user@example.com", displayName: "User")
        let client = FakeAuthClient(user: user)
        await client.setTeams([CMUXAuthTeam(id: "team-a", displayName: "Alpha")])
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")

        await #expect(throws: AuthClientError.teamNotAvailable) {
            try await coordinator.selectTeam(id: "not-a-member")
        }
        #expect(coordinator.resolvedTeamID == "team-a")
    }

    #if DEBUG
    private func makeFixtureCoordinator(client: FakeAuthClient, environment: [String: String]) -> AuthCoordinator {
        makeCoordinator(
            client: client,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: environment.merging(["CMUX_UITEST_AUTH_FIXTURE": "1"]) { current, _ in current },
                includesDevAuth: false
            )
        )
    }

    @Test func fixtureSessionLoadsTeamsFromInjectedClient() async {
        let client = FakeAuthClient()
        await client.setTeams([
            CMUXAuthTeam(id: "team-a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team-b", displayName: "Beta")
        ])
        let coordinator = makeFixtureCoordinator(
            client: client,
            environment: ["CMUX_UITEST_AUTH_FIXTURE_TEAMS": "[]"]
        )

        await coordinator.checkExistingSession()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.availableTeams.map(\.id) == ["team-a", "team-b"])
        #expect(coordinator.resolvedTeamID == "team-a")
        #expect(coordinator.authenticatedTeamScope?.teamID == "team-a")
    }

    /// Fixture launches that don't ask for fixture teams must not wait on a
    /// team lookup through the live client.
    @Test func fixtureSessionWithoutFixtureTeamsSkipsTeamLookup() async {
        let client = FakeAuthClient()
        await client.setTeams([CMUXAuthTeam(id: "team-a", displayName: "Alpha")])
        let coordinator = makeFixtureCoordinator(client: client, environment: [:])

        await coordinator.checkExistingSession()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.availableTeams.isEmpty)
        #expect(coordinator.authenticatedTeamScope == nil)
    }
    #endif
}
