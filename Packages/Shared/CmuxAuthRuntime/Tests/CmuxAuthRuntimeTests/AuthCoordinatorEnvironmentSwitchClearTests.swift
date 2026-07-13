import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The auth-environment-switch clear (``AuthLaunchOptions/clearStaleAuthOnLaunch``):
/// an install whose resolved Stack project changed since its last launch (an
/// iOS dev install rebuilt for production auth, or back) must drop the other
/// project's local state WITHOUT inheriting the UI-test clear's
/// stop-everything semantics — the same launch's DEBUG auto-login credentials
/// must still sign in, and the persisted-token clear must land before the
/// restore probe so stale foreign-project tokens cannot suppress it
/// (https://github.com/manaflow-ai/cmux/issues/7145).
@MainActor
@Suite struct AuthCoordinatorEnvironmentSwitchClearTests {
    private let staleUser = CMUXAuthUser(id: "stale-dev-user", primaryEmail: "dev@x.com", displayName: "Dev")

    /// Build a coordinator over a key-value store pre-populated with the
    /// previous environment's session (cached user + has-tokens flag).
    private func makeCoordinatorWithStaleSession(
        client: FakeAuthClient,
        launch: AuthLaunchOptions
    ) throws -> (AuthCoordinator, FakeKeyValueStore) {
        let store = FakeKeyValueStore()
        try CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user").save(staleUser)
        store.set(true, forKey: "has_tokens")
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: launch
        )
        return (coordinator, store)
    }

    @Test func switchClearPrimesSignedOutInsteadOfStaleIdentity() async throws {
        // The stale cached identity belongs to the other Stack project; it
        // must not prime (or even flash) under the new environment.
        let client = FakeAuthClient(access: "stale-dev-access", refresh: "stale-dev-refresh")
        let (coordinator, store) = try makeCoordinatorWithStaleSession(
            client: client,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false,
                clearStaleAuthOnLaunch: true
            )
        )

        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)

        coordinator.start()
        await coordinator.awaitBootstrapped()

        // The persisted foreign-project tokens were dropped (locally, no
        // network revocation) and nothing restored from them.
        let clears = await client.clearLocalSessionCount
        #expect(clears >= 1)
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
    }

    @Test func switchClearStillRunsDevAutoLoginOnTheSameLaunch() async throws {
        // Regression: folding the switch into clearAuthRequested suppressed
        // auto-login (its priming clears and RETURNS), so the first normal
        // reload after switching auth projects launched signed out instead of dogfooding
        // signed in. The stale tokens must also be cleared BEFORE the restore
        // probe — were they still present, shouldStartAutoLogin would skip
        // the credentials (this test fails exactly that way if the clear
        // moves after the probe).
        let freshUser = CMUXAuthUser(id: "dogfood", primaryEmail: "dog@x.com", displayName: "Dog")
        let client = FakeAuthClient(access: "stale-prod-access", refresh: "stale-prod-refresh", user: freshUser)
        let (coordinator, _) = try makeCoordinatorWithStaleSession(
            client: client,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_STACK_EMAIL": "dog@x.com",
                    "CMUX_UITEST_STACK_PASSWORD": "pw",
                ],
                includesDevAuth: true,
                clearStaleAuthOnLaunch: true
            )
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        let credential = await client.signedInWithCredential
        #expect(credential?.email == "dog@x.com")
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.currentUser == freshUser)
    }

    @Test func uiTestClearKeepsSuppressingAutoLogin() async throws {
        // The pre-existing CMUX_UITEST_CLEAR_AUTH contract is untouched: it
        // clears and stops, credentials and all.
        let client = FakeAuthClient(access: "stale", user: staleUser)
        let (coordinator, _) = try makeCoordinatorWithStaleSession(
            client: client,
            launch: AuthLaunchOptions(
                clearAuthRequested: true,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_STACK_EMAIL": "dog@x.com",
                    "CMUX_UITEST_STACK_PASSWORD": "pw",
                ],
                includesDevAuth: true
            )
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        let credential = await client.signedInWithCredential
        #expect(credential == nil)
        #expect(coordinator.isAuthenticated == false)
    }
}
