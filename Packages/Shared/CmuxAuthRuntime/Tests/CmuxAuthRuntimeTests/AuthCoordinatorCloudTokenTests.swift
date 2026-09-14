import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct AuthCoordinatorCloudTokenTests {
    @Test func cancelledCloudCallerDoesNotReturnCredentials() async throws {
        let client = FakeAuthClient(access: "access", refresh: "refresh")
        let coordinator = makeCoordinator(client: client)
        let gate = TestPhaseSignal()
        let caller = Task {
            await gate.waitUntilStarted()
            return try await coordinator.currentTokens()
        }
        caller.cancel()
        await gate.markStarted()
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    @Test func cloudCallerCancellationDetachesFromStalledTokenWork() async throws {
        let client = HangingLaunchTokenProbeAuthClient(
            user: CMUXAuthUser(id: "fixture", primaryEmail: nil, displayName: nil)
        )
        let coordinator = makeCoordinator(client: client)
        let completion = TestPhaseSignal()
        let caller = Task {
            let result: Result<(accessToken: String, refreshToken: String), any Error>
            do { result = .success(try await coordinator.currentTokens()) }
            catch { result = .failure(error) }
            await completion.markStarted()
            return result
        }
        await client.accessTokenDidStart()
        caller.cancel()
        let detached = await completesWithinDeadline(completion)
        await client.releaseHangingAccessTokenProbe()
        let result = await caller.value
        #expect(detached, "Cancelled list/stats auth must finish before stalled transport is released")
        if case let .failure(error) = result { #expect(error is CancellationError) }
        else { Issue.record("Cancelled cloud caller returned credentials") }
    }

    @Test func cloudCallerDeadlinePreservesRecoverableSession() async throws {
        let client = HangingLaunchTokenProbeAuthClient(
            user: CMUXAuthUser(id: "fixture", primaryEmail: nil, displayName: nil)
        )
        let coordinator = makeCoordinator(client: client, timeout: .milliseconds(50))
        let completion = TestPhaseSignal()
        let caller = Task {
            let result: Result<(accessToken: String, refreshToken: String), any Error>
            do { result = .success(try await coordinator.currentTokens()) }
            catch { result = .failure(error) }
            await completion.markStarted()
            return result
        }
        await client.accessTokenDidStart()
        let bounded = await completesWithinDeadline(completion)
        await client.releaseHangingAccessTokenProbe()
        let result = await caller.value
        #expect(bounded, "Cloud auth must obey its injected network deadline")
        if case let .failure(error) = result { #expect(error as? AuthError == .timedOut) }
        else { Issue.record("Stalled refresh unexpectedly returned credentials") }
        #expect(await client.refreshToken() == "refresh")
    }

    private func completesWithinDeadline(_ completion: TestPhaseSignal) async -> Bool {
        let stream = AsyncStream<Bool> { continuation in
            let waiter = Task { await completion.waitUntilStarted(); continuation.yield(true); continuation.finish() }
            let deadline = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { continuation.yield(false); continuation.finish() }
            }
            continuation.onTermination = { _ in waiter.cancel(); deadline.cancel() }
        }
        for await value in stream { return value }
        return false
    }

    private func makeCoordinator(client: any AuthClient, timeout: Duration = .seconds(1)) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "team"),
            anchor: FakeAnchor(), config: .test, launch: .plain(),
            timeouts: AuthTimeouts(interactiveFlow: .seconds(1), network: timeout)
        )
    }
}
