import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthSocketCommandServiceTests {
    @Test func detachedStatusMatchesLegacyUnauthenticatedPayload() async {
        let service = AuthSocketCommandService(coordinator: nil, browserSignIn: nil)

        let payload = await service.status(timedOut: true)

        #expect(payload == AuthSocketStatusPayload(
            signedIn: false,
            isRestoringSession: false,
            isLoading: false,
            timedOut: true
        ))
    }

    @Test func statusMirrorsCoordinatorUserAndTeams() async throws {
        let user = CMUXAuthUser(id: "user_1", primaryEmail: "u@example.test", displayName: "User One")
        let teamA = CMUXAuthTeam(id: "team_a", displayName: "Team A", slug: "a")
        let teamB = CMUXAuthTeam(id: "team_b", displayName: "Team B", slug: nil)
        let client = FakeAuthClient(user: user)
        await client.setTeams([teamA, teamB])
        let coordinator = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "u@example.test", password: "pw")
        let service = AuthSocketCommandService(coordinator: coordinator, browserSignIn: nil)

        let payload = await service.status(timedOut: false)

        #expect(payload.signedIn)
        #expect(payload.isRestoringSession == false)
        #expect(payload.isLoading == false)
        #expect(payload.timedOut == false)
        #expect(payload.user == AuthSocketUserPayload(id: "user_1", email: "u@example.test", displayName: "User One"))
        #expect(payload.selectedTeamID == "team_a")
        #expect(payload.teams == [
            AuthSocketTeamPayload(id: "team_a", displayName: "Team A", slug: "a"),
            AuthSocketTeamPayload(id: "team_b", displayName: "Team B", slug: nil),
        ])
    }

    @Test func signInURLUsesBrowserFlowManualURL() {
        let harness = makeBrowserHarness()
        let service = AuthSocketCommandService(coordinator: harness.coordinator, browserSignIn: harness.flow)

        let payload = service.signInURL()

        #expect(payload.url?.hasPrefix("https://example.test/handler/sign-in?cmux_auth_state=") == true)
    }

    @Test func beginSignInWithoutBrowserFlowReportsTimedOutStatus() async {
        let service = AuthSocketCommandService(coordinator: nil, browserSignIn: nil)

        let payload = await service.beginSignIn(timeoutSeconds: 0)

        #expect(payload == AuthSocketStatusPayload(
            signedIn: false,
            isRestoringSession: false,
            isLoading: false,
            timedOut: true
        ))
    }

    @Test func signOutWithoutBrowserFlowReturnsStatusPayload() async {
        let service = AuthSocketCommandService(coordinator: nil, browserSignIn: nil)

        let payload = await service.signOut(timeoutSeconds: 5)

        #expect(payload == AuthSocketStatusPayload(
            signedIn: false,
            isRestoringSession: false,
            isLoading: false,
            timedOut: false
        ))
    }

    private func makeCoordinator(client: any AuthClient) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
    }

    private func makeBrowserHarness() -> (flow: HostBrowserSignInFlow, coordinator: AuthCoordinator) {
        let keyValueStore = FakeKeyValueStore()
        let tokenStore = FlowInMemoryTokenStore()
        let client = FlowFakeAuthClient(user: nil, store: tokenStore)
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: keyValueStore, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: keyValueStore, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: keyValueStore, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        let flow = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: FakeBrowserAuthSessionFactory(),
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\($0)")! },
            callbackScheme: { "cmux-dev" }
        )
        return (flow, coordinator)
    }
}
