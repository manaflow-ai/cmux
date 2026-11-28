import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Round-10 dogfood regression: "sign out doesn't work when there's no wifi".
///
/// Offline, the Stack session-revocation DELETE neither completes nor fails
/// promptly (the SDK retries the idempotent request with exponential backoff,
/// each attempt with a 30s timeout), and sign-out awaited it before clearing
/// any local session state, so the user stayed signed in indefinitely.
/// Sign-out must be local-first: the device signs out immediately regardless
/// of connectivity, and the server-side revocation is a bounded best-effort
/// tail on the injected clock.
@MainActor
@Suite struct AuthCoordinatorSignOutOfflineTests {
    @Test func signOutWithHangingRevocationSignsOutLocallyAndCompletes() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingSignOutAuthClient(user: user)
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            clock: clock
        )
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        let signOut = Task { await coordinator.signOut() }
        await client.revocationDidStart()

        // The revocation call is in flight and will never return (offline).
        // The device must ALREADY be signed out locally: published state,
        // caches, and the local token store cleared, no network in the path.
        #expect(coordinator.isAuthenticated == false)
        #expect(coordinator.currentUser == nil)
        #expect(store.bool(forKey: "has_tokens") == false)
        #expect(await client.localSessionCleared)

        // Drive the teardown deadline (parked on the injected clock) so the
        // bounded best-effort revocation is cancelled and signOut() returns.
        let pump = Task {
            await clock.waitUntilSleepers()
            clock.advance(by: .seconds(5))
        }
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await signOut.value; return true }
            group.addTask {
                // Real-time watchdog: the unfixed coordinator parks nothing on
                // the injected clock and awaits the hanging revocation
                // unbounded; turn that hang into a failure instead of wedging
                // the suite. Deterministic-sleep-in-tests carve-out. The
                // watchdog also cancels the wedged sign-out itself: awaiting a
                // non-throwing `Task.value` is not cancellation-interruptible,
                // so without this the group could never join its first child
                // and the suite would hang on the unfixed coordinator.
                try? await Task.sleep(for: .seconds(2))
                signOut.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(completed, "sign-out must complete once the teardown deadline fires")
        pump.cancel()
        await signOut.value
        #expect(coordinator.isAuthenticated == false)
    }

    @Test func teardownDeadlineDuringTokenMintSkipsSignOutHook() async throws {
        // The teardown's first leg is minting a usable access token from the
        // captured refresh token. Offline, that refresh hangs too; when the
        // teardown deadline cancels it, the refresh path swallows the
        // cancellation into `nil` and execution continues on the CANCELLED
        // task. The sign-out hook (the push-token DELETE in production) must
        // not run past the deadline: the deadline bounds the entire server
        // teardown, and a post-deadline hook can interleave with a later
        // sign-in's setup.
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = HangingTokenMintAuthClient(user: user)
        let store = FakeKeyValueStore()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            clock: clock
        )
        try await coordinator.signInWithPassword(email: "a@b.com", password: "pw")
        #expect(coordinator.isAuthenticated)

        let hookRuns = SignOutHookCounter()
        let signOut = Task {
            await coordinator.signOut(onSignedOut: { _, _ in await hookRuns.increment() })
        }
        await client.mintDidStart()

        // Already signed out locally while the mint hangs.
        #expect(coordinator.isAuthenticated == false)

        // Fire the teardown deadline while the mint is parked.
        await clock.waitUntilSleepers()
        clock.advance(by: .seconds(5))
        await signOut.value

        #expect(coordinator.isAuthenticated == false)
        #expect(await hookRuns.value == 0, "the sign-out hook must not run after the teardown deadline")
    }
}

/// Counts sign-out hook runs across actor hops.
private actor SignOutHookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
