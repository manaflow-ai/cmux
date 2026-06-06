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

    @Test func signOutRunsHookWhileTokensStillValid() async throws {
        // The push-token DELETE runs as the onSignedOut hook and needs a valid
        // access token. Regression: the hook used to run after client.signOut()
        // revoked the session, so the DELETE was silently skipped.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        let probe = TokenProbe()
        await coordinator.signOut(onSignedOut: {
            let token = try? await coordinator.accessToken()
            await probe.set(token)
        })

        #expect(await probe.value != nil)  // hook saw a valid token (ran before revoke)
        #expect(coordinator.isAuthenticated == false)  // session revoked afterward
    }

    @Test func signOutJoinsAndCancelsSlowTeardownAtDeadline() async throws {
        // Regression: the teardown must be STRUCTURED (joined), not detached. A
        // detached hook could outlive signOut() and, after a later sign-in,
        // rebuild its push-token DELETE from the new account's tokens. With a
        // short deadline the task group cancels the slow hook and joins it before
        // signOut returns, so by the time signOut returns the hook has already
        // been cancelled (never left running) and sign-out wasn't blocked for the
        // hook's full duration.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        let (coordinator, _) = makeCoordinator(client: client)
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")

        let outcome = TeardownOutcomeProbe()
        await coordinator.signOut(
            onSignedOut: {
                await outcome.markStarted()
                do {
                    // Cancellation-aware slow work, like the URLSession DELETE.
                    try await Task.sleep(for: .seconds(60))
                    await outcome.markFinished()
                } catch {
                    await outcome.markCancelled()
                }
            },
            teardownTimeout: .milliseconds(50)
        )

        #expect(await outcome.started)
        #expect(await outcome.cancelled)          // joined + cancelled before return
        #expect(await outcome.finished == false)  // the 60s path never completed
        #expect(coordinator.isAuthenticated == false)
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
        await coordinator.awaitBootstrapped()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
    }

    @Test func awaitBootstrappedReturnsWithoutStart() async {
        let (coordinator, _) = makeCoordinator(client: FakeAuthClient())
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func currentTokensReturnsPairAfterRestore() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let (coordinator, _) = makeCoordinator(client: client)
        coordinator.start()

        let tokens = try await coordinator.currentTokens()

        #expect(tokens.accessToken == "access-1")
        #expect(tokens.refreshToken == "refresh-1")
    }

    @Test func currentTokensThrowsWhenRefreshTokenMissing() async {
        let client = FakeAuthClient(access: "access-only")
        let (coordinator, _) = makeCoordinator(client: client)
        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.currentTokens()
        }
    }

    @Test func completeExternalSignInPublishesSeededSession() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(user: user)
        await client.setTeams([CMUXAuthTeam(id: "team_a", displayName: "Alpha")])
        let (coordinator, store) = makeCoordinator(client: client)

        // Simulate the macOS browser flow seeding tokens out-of-band.
        await client.setTokens(access: "seeded-access", refresh: "seeded-refresh")
        try await coordinator.completeExternalSignIn()

        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == user)
        #expect(coordinator.resolvedTeamID == "team_a")
        #expect(store.bool(forKey: "has_tokens"))
    }

    @Test func completeExternalSignInFailureStaysSignedOut() async {
        let client = FakeAuthClient()
        await client.setThrowOnCurrentUser(AuthError.unauthorized)
        let (coordinator, _) = makeCoordinator(client: client)

        await #expect(throws: AuthError.unauthorized) {
            try await coordinator.completeExternalSignIn()
        }
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.isLoading == false)
    }
}
