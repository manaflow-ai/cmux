import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records invalidation-hook invocations and lets a test await the first one:
/// the coordinator fires the hook into a fire-and-forget task, so assertions
/// must synchronize on the recorded call instead of racing it.
actor SessionInvalidationRecorder {
    private(set) var pairs: [(accessToken: String, refreshToken: String)] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(accessToken: String, refreshToken: String) {
        pairs.append((accessToken: accessToken, refreshToken: refreshToken))
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }

    func waitForFirstInvocation() async {
        if !pairs.isEmpty { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// The `onSessionInvalidated` backstop must fire exactly on definitive,
/// NON-interactive session death (vanished user, definitive refresh
/// rejection) with the last-known token pair, and must stay silent for
/// interactive sign-out, whose flow hooks own the same teardown. Firing twice
/// would double-run best-effort deregistration; firing on sign-out would
/// replay credentials the user deliberately destroyed.
@MainActor
@Suite struct AuthCoordinatorSessionInvalidatedHookTests {
    private func makeCoordinator(
        client: FakeAuthClient,
        recorder: SessionInvalidationRecorder
    ) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            onSessionInvalidated: { accessToken, refreshToken in
                await recorder.record(accessToken: accessToken, refreshToken: refreshToken)
            }
        )
    }

    @Test func vanishedUserFiresHookWithLastKnownPair() async throws {
        // The session dies remotely while its tokens are still stored (the
        // "vanished user" validation verdict). The hook must receive the pair
        // the launch probe captured, because the store is cleared right after.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let recorder = SessionInvalidationRecorder()
        let coordinator = makeCoordinator(client: client, recorder: recorder)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)

        await client.setUser(nil)
        await coordinator.revalidateSession()

        await recorder.waitForFirstInvocation()
        let pairs = await recorder.pairs
        #expect(pairs.count == 1)
        #expect(pairs.first?.accessToken == "access-1")
        #expect(pairs.first?.refreshToken == "refresh-1")
        #expect(!coordinator.isAuthenticated)
    }

    @Test func definitiveTokenDeathFiresHookOnceWithLastKnownPair() async throws {
        // The SDK dropped a definitively rejected refresh token between reads:
        // the next token request finds available-but-empty storage. The hook
        // fires with the last-known pair, and only once: a second dead read
        // has nothing left to hand over.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let recorder = SessionInvalidationRecorder()
        let coordinator = makeCoordinator(client: client, recorder: recorder)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)

        await client.setTokens(access: nil, refresh: nil)
        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.accessToken()
        }

        await recorder.waitForFirstInvocation()
        var pairs = await recorder.pairs
        #expect(pairs.count == 1)
        #expect(pairs.first?.accessToken == "access-1")
        #expect(pairs.first?.refreshToken == "refresh-1")
        #expect(!coordinator.isAuthenticated)

        await #expect(throws: AuthError.unauthorized) {
            _ = try await coordinator.accessToken()
        }
        for _ in 0..<20 { await Task.yield() }
        pairs = await recorder.pairs
        #expect(pairs.count == 1)
    }

    @Test func interactiveSignOutDoesNotFireHook() async throws {
        // Interactive sign-out captures its own pre-clear credentials and runs
        // the composition's teardown through the flow's `onSignedOut`; the
        // invalidation backstop must not double-fire that teardown.
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let client = FakeAuthClient(access: "access-1", refresh: "refresh-1", user: user)
        let recorder = SessionInvalidationRecorder()
        let coordinator = makeCoordinator(client: client, recorder: recorder)
        coordinator.start()
        await coordinator.awaitBootstrapped()
        #expect(coordinator.isAuthenticated)

        await coordinator.signOut()

        // The hook spawn is synchronous with the clear; if sign-out had fired
        // it, the recorder would observe it within these yields.
        for _ in 0..<20 { await Task.yield() }
        let pairs = await recorder.pairs
        #expect(pairs.isEmpty)
        #expect(!coordinator.isAuthenticated)
        // The pair was consumed by the sign-out clear, so no later failure
        // path can replay the destroyed session's credentials.
        #expect(coordinator.lastKnownTokenPair == nil)
    }
}
