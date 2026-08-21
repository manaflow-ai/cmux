import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The auth-environment-switch clear (``AuthLaunchOptions/clearStaleAuthOnLaunch``):
/// an install whose resolved Stack project changed since its last launch (an
/// iOS dev install rebuilt with `--prod-auth`, or back) must drop the other
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
        // reload after --prod-auth launched signed out instead of dogfooding
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

    @Test func selectedDevProfileReplacesAStaleSessionOnTheSameLaunch() async throws {
        let selectedUser = CMUXAuthUser(
            id: "selected-personal-user",
            primaryEmail: "person@manaflow.ai",
            displayName: "Person"
        )
        let client = FakeAuthClient(
            access: "stale-agent-access",
            refresh: "stale-agent-refresh",
            user: selectedUser
        )
        let (coordinator, store) = try makeCoordinatorWithStaleSession(
            client: client,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_STACK_EMAIL": "person@manaflow.ai",
                    "CMUX_UITEST_STACK_PASSWORD": "pw",
                ],
                includesDevAuth: true,
                replaceStoredSessionWithAutoLogin: true
            )
        )

        coordinator.start()
        await coordinator.awaitBootstrapped()

        let clears = await client.clearLocalSessionCount
        let credential = await client.signedInWithCredential
        #expect(clears >= 1)
        #expect(store.bool(forKey: "has_tokens"))
        #expect(credential?.email == "person@manaflow.ai")
        #expect(coordinator.currentUser == selectedUser)
    }

    @Test func secondCoordinatorInSameProcessPrimesSignedOutAndClearsLocally() async throws {
        // The live backend-environment switch rebuilds the auth graph
        // IN-PROCESS: coordinator A (the old environment) is signed in over
        // the shared stores, then coordinator B is built over the SAME
        // stores with clearStaleAuthOnLaunch. B must prime signed-out
        // synchronously at init (no stale-identity flash while A still
        // exists) and clear the local session on start() without any network
        // revocation (the switch's sign-out step already revoked under the
        // old environment).
        let store = FakeKeyValueStore()
        let signedInUser = CMUXAuthUser(id: "old-env-user", primaryEmail: "old@x.com", displayName: "Old")
        let clientA = FakeAuthClient(user: signedInUser)
        let coordinatorA = AuthCoordinator(
            client: clientA,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        try await coordinatorA.signInWithPassword(email: "old@x.com", password: "pw")
        #expect(coordinatorA.isAuthenticated)
        #expect(store.bool(forKey: "has_tokens"))

        let clientB = FakeAuthClient(access: "old-env-access", refresh: "old-env-refresh")
        let coordinatorB = AuthCoordinator(
            client: clientB,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false,
                clearStaleAuthOnLaunch: true
            )
        )

        // Synchronous priming, before start(): the shared caches are already
        // signed out even though coordinator A lives on in the process.
        #expect(coordinatorB.isAuthenticated == false)
        #expect(coordinatorB.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)

        coordinatorB.start()
        await coordinatorB.awaitBootstrapped()

        // Local clear only: the persisted tokens were dropped through B's
        // client, with no network revocation from either coordinator.
        let clears = await clientB.clearLocalSessionCount
        #expect(clears >= 1)
        #expect(coordinatorB.isAuthenticated == false)
        #expect(coordinatorB.currentUser == nil)
        let revokesA = await clientA.revokeCount
        let revokesB = await clientB.revokeCount
        #expect(revokesA == 0)
        #expect(revokesB == 0)
    }

    @Test func suppressedClearRebuildRestoresAParkedSession() async throws {
        // The backend-environment switch parks the old session
        // (detachSessionLeavingTokens leaves the token slot intact) and arms
        // the one-shot rebuild marker, so the rebuilt coordinator is
        // composed WITHOUT clearStaleAuthOnLaunch even though the resolved
        // Stack project changed. The rebuilt coordinator must restore the
        // TARGET's parked session from its surviving tokens: no local clear,
        // no revocation, signed in without any prompt.
        let store = FakeKeyValueStore()
        let parkedUser = CMUXAuthUser(
            id: "parked-user",
            primaryEmail: "aziz@manaflow.ai",
            displayName: "Aziz"
        )
        let clientA = FakeAuthClient(user: parkedUser)
        let coordinatorA = AuthCoordinator(
            client: clientA,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        try await coordinatorA.signInWithPassword(email: "aziz@manaflow.ai", password: "pw")
        await coordinatorA.detachSessionLeavingTokens()
        #expect(coordinatorA.isAuthenticated == false)
        let parkedAccess = await clientA.storedAccessToken()
        try #require(parkedAccess != nil)

        // The rebuilt coordinator resolves the parked project's own slot
        // (per-project stores), so its client still holds the parked tokens.
        let clientB = FakeAuthClient(
            access: parkedAccess,
            refresh: "parked-refresh",
            user: parkedUser
        )
        let coordinatorB = AuthCoordinator(
            client: clientB,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false,
                // The consumed rebuild marker suppressed the project-switch
                // verdict, so the composition passes false here.
                clearStaleAuthOnLaunch: false
            )
        )

        coordinatorB.start()
        await coordinatorB.awaitBootstrapped()

        #expect(coordinatorB.isAuthenticated)
        #expect(coordinatorB.currentUser == parkedUser)
        let clearsA = await clientA.clearLocalSessionCount
        let clearsB = await clientB.clearLocalSessionCount
        let revokesA = await clientA.revokeCount
        let revokesB = await clientB.revokeCount
        #expect(clearsA == 0)
        #expect(clearsB == 0)
        #expect(revokesA == 0)
        #expect(revokesB == 0)
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
