import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite("Auth coordinator team actions")
struct AuthCoordinatorTeamActionsTests {
    private func makeCoordinator(
        client: FakeAuthClient,
        launch: AuthLaunchOptions = .plain(),
        timeout: Duration = .seconds(60),
        clock: any Clock<Duration> = ContinuousClock()
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: launch,
            timeouts: AuthTimeouts(interactiveFlow: .seconds(1), network: timeout),
            clock: clock
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

    @Test func stalledCreateTimesOutInsteadOfLeavingThePickerFrozen() async throws {
        let clock = ManualTestClock()
        let client = FakeAuthClient(user: CMUXAuthUser(
            id: "user", primaryEmail: "user@example.com", displayName: "User"
        ))
        await client.setTeams([CMUXAuthTeam(id: "team-a", displayName: "Alpha")])
        let coordinator = makeCoordinator(client: client, timeout: .seconds(2), clock: clock)
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamCreate(started: started, release: release)

        let create = Task { try await coordinator.createTeam(displayName: "Stalled Team") }
        await started.waitUntilStarted()
        await clock.waitUntilSleepers()
        clock.advance(by: .seconds(2))

        await #expect(throws: AuthError.timedOut) { try await create.value }
        #expect(!coordinator.isCreatingTeam)
        await release.release()
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

    @Test func switchDuringPendingCreateIsRefusedBeforeReachingTheServer() async throws {
        let (coordinator, client) = try await makeSignedInCoordinator()
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamCreate(started: started, release: release)
        let create = Task { try await coordinator.createTeam(displayName: "New Team") }
        await started.waitUntilStarted()

        await #expect(throws: AuthTeamChangeInProgressError()) {
            try await coordinator.selectTeam(id: "team-b")
        }
        #expect(await client.teamSelectionCount == 0)
        #expect(coordinator.resolvedTeamID == "team-a")

        await release.release()
        let team = try await create.value
        #expect(coordinator.resolvedTeamID == team.id)
    }

    @Test func createDuringPendingSwitchIsRefusedBeforeReachingTheServer() async throws {
        let (coordinator, client) = try await makeSignedInCoordinator()
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamSelection(started: started, release: release)
        let select = Task { try await coordinator.selectTeam(id: "team-b") }
        await started.waitUntilStarted()

        await #expect(throws: AuthTeamChangeInProgressError()) {
            _ = try await coordinator.createTeam(displayName: "New Team")
        }
        #expect(await client.teamCreateCount == 0)

        await release.release()
        try await select.value
        #expect(coordinator.resolvedTeamID == "team-b")
    }

    @Test func secondCreateIsRefusedAndTheFirstCreateCompletes() async throws {
        let (coordinator, client) = try await makeSignedInCoordinator()
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamCreate(started: started, release: release)
        let first = Task { try await coordinator.createTeam(displayName: "First Team") }
        await started.waitUntilStarted()

        await #expect(throws: AuthTeamChangeInProgressError()) {
            _ = try await coordinator.createTeam(displayName: "Second Team")
        }
        #expect(await client.teamCreateCount == 1)

        await release.release()
        let team = try await first.value
        #expect(team.displayName == "First Team")
        #expect(coordinator.resolvedTeamID == team.id)
    }

    @Test func createWaitsForASupersededSwitchStillInFlight() async throws {
        let (coordinator, client) = try await makeSignedInCoordinator()
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamSelection(started: started, release: release)
        let first = Task { try await coordinator.selectTeam(id: "team-b") }
        await started.waitUntilStarted()
        try await coordinator.selectTeam(id: "team-a")

        await #expect(throws: AuthTeamChangeInProgressError()) {
            _ = try await coordinator.createTeam(displayName: "New Team")
        }
        #expect(await client.teamCreateCount == 0)

        await release.release()
        await #expect(throws: AuthError.unauthorized) { try await first.value }
        #expect(coordinator.resolvedTeamID == "team-a")
        let team = try await coordinator.createTeam(displayName: "New Team")
        #expect(coordinator.resolvedTeamID == team.id)
    }

    @Test func createRemainsExclusiveWhileSelectingTheNewTeam() async throws {
        let (coordinator, client) = try await makeSignedInCoordinator()
        let started = TestPhaseSignal()
        let release = TestContinuationBlocker()
        await client.holdNextTeamSelection(started: started, release: release)
        let create = Task { try await coordinator.createTeam(displayName: "New Team") }
        await started.waitUntilStarted()

        await #expect(throws: AuthTeamChangeInProgressError()) {
            try await coordinator.selectTeam(id: "team-b")
        }
        await #expect(throws: AuthTeamChangeInProgressError()) {
            _ = try await coordinator.createTeam(displayName: "Another Team")
        }
        #expect(await client.teamSelectionCount == 1)
        #expect(await client.teamCreateCount == 1)
        #expect(coordinator.resolvedTeamID == "team-a")

        await release.release()
        let team = try await create.value
        #expect(coordinator.resolvedTeamID == team.id)
        try await coordinator.selectTeam(id: "team-b")
        #expect(coordinator.resolvedTeamID == "team-b")
    }

    private func makeSignedInCoordinator() async throws -> (AuthCoordinator, FakeAuthClient) {
        let user = CMUXAuthUser(id: "user", primaryEmail: "user@example.com", displayName: "User")
        let client = FakeAuthClient(user: user)
        await client.setTeams([
            CMUXAuthTeam(id: "team-a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team-b", displayName: "Beta")
        ])
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "user@example.com", password: "password")
        return (coordinator, client)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The fake client never entered the expected phase.")
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
