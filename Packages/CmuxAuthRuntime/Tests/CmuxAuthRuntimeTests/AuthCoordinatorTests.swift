import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorTests {
    private func makeCoordinator(
        client: FakeAuthClient,
        launch: AuthLaunchOptions = .plain(),
        isOnline: @escaping @Sendable () async -> Bool = { true }
    ) -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: launch,
            isOnline: isOnline
        )
        return (coordinator, store)
    }

    @Test func startsSignedOut() {
        let (coordinator, _) = makeCoordinator(client: FakeAuthClient())
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
    }

    @Test func passwordSignInAuthenticatesAndCaches() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = makeCoordinator(client: client)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(store.bool(forKey: "has_tokens"))
        let recorded = await client.signedInWithCredential
        #expect(recorded?.email == "a@b.com")
    }

    @Test func magicLinkRequiresPriorNonce() async {
        let (coordinator, _) = makeCoordinator(client: FakeAuthClient())
        await #expect(throws: AuthError.invalidCode) {
            try await coordinator.verifyCode("000000")
        }
    }

    @Test func sendCodeThenVerifySignsIn() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(client: client)

        try await coordinator.sendCode(to: "a@b.com")
        try await coordinator.verifyCode("123456")

        #expect(coordinator.isAuthenticated)
        let didMagicLink = await client.signedInWithMagicLink
        #expect(didMagicLink)
    }

    @Test func offlineFailsFast() async {
        let (coordinator, _) = makeCoordinator(client: FakeAuthClient(), isOnline: { false })
        await #expect(throws: AuthError.offline) {
            try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        }
    }

    @Test func oauthAppleAndGoogleRouteToProviders() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(client: client)

        try await coordinator.signInWithApple()
        try await coordinator.signInWithGoogle()

        let providers = await client.oauthProviders
        #expect(providers == ["apple", "google"])
    }

    @Test func signOutClearsStateAndRunsHook() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, store) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        let ranHook = HookFlag()
        await coordinator.signOut(onSignedOut: { await ranHook.fire() })

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(await ranHook.fired)
    }

    @Test func devAuthFortyTwoShortcutSignsIn() async throws {
        let user = CMUXAuthUser(id: "debug", primaryEmail: "l@l.com", displayName: "L")
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(
            client: client,
            launch: .plain(includesDevAuth: true)
        )

        try await coordinator.sendCode(to: "42")

        #expect(coordinator.isAuthenticated)
        let recorded = await client.signedInWithCredential
        #expect(recorded?.email == "l@l.com")
    }

    @Test func devAuthShortcutOffWithoutDevAuth() async throws {
        let client = FakeAuthClient(user: nil)
        let (coordinator, _) = makeCoordinator(
            client: client,
            launch: .plain(includesDevAuth: false)
        )
        // Without dev-auth, "42" is treated as a normal email -> magic link path.
        try await coordinator.sendCode(to: "42")
        let recorded = await client.signedInWithCredential
        #expect(recorded == nil)
    }

    @Test func accessTokenThrowsWhenSignedOut() async {
        let (coordinator, _) = makeCoordinator(client: FakeAuthClient())
        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.accessToken()
        }
    }

    @Test func signInRefreshesTeamsAndResolvesSelection() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams([
            CMUXAuthTeam(id: "team_a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team_b", displayName: "Beta"),
        ])
        let (coordinator, store) = makeCoordinator(client: client)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.availableTeams.count == 2)
        // No prior selection -> resolves (and persists) the first team.
        #expect(coordinator.resolvedTeamID == "team_a")
        #expect(store.string(forKey: "selected_team") == "team_a")
    }

    @Test func persistedTeamSelectionSurvivesSignIn() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams([
            CMUXAuthTeam(id: "team_a", displayName: "Alpha"),
            CMUXAuthTeam(id: "team_b", displayName: "Beta"),
        ])
        let (coordinator, store) = makeCoordinator(client: client)
        coordinator.selectedTeamID = "team_b"

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.resolvedTeamID == "team_b")
        #expect(store.string(forKey: "selected_team") == "team_b")
    }

    @Test func staleTeamSelectionFallsBackToFirstTeam() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams([CMUXAuthTeam(id: "team_a", displayName: "Alpha")])
        let (coordinator, _) = makeCoordinator(client: client)
        coordinator.selectedTeamID = "team_gone"

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.resolvedTeamID == "team_a")
        #expect(coordinator.selectedTeamID == "team_a")
    }

    @Test func teamFetchFailureDoesNotUnwindSignIn() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setThrowOnListTeams(AuthError.networkError)
        let (coordinator, _) = makeCoordinator(client: client)

        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.availableTeams.isEmpty)
    }

    @Test func signOutClearsTeamsAndSelection() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams([CMUXAuthTeam(id: "team_a", displayName: "Alpha")])
        let (coordinator, store) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        await coordinator.signOut()

        #expect(coordinator.availableTeams.isEmpty)
        #expect(coordinator.selectedTeamID == nil)
        #expect(coordinator.resolvedTeamID == nil)
        #expect(store.string(forKey: "selected_team") == nil)
    }

    @Test func restoreWithStoredTokensValidatesSession() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: user)
        let (coordinator, _) = makeCoordinator(client: client)

        coordinator.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
    }
}
