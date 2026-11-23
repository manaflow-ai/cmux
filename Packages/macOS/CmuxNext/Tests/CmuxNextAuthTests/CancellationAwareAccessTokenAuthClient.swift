import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

actor CancellationAwareAccessTokenAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var accessStarted = false
    private var accessCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private let blocker = TestContinuationBlocker()

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func accessDidStart() async {
        if accessStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func accessDidCancel() async {
        if accessCancelled { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func releaseAccessToken() async {
        await blocker.release()
    }

    func accessToken() async -> String? {
        accessStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withTaskCancellationHandler {
            await blocker.wait()
        } onCancel: {
            Task { await self.markAccessCancelled() }
        }
        return nil
    }

    private func markAccessCancelled() {
        accessCancelled = true
        for waiter in cancelWaiters { waiter.resume() }
        cancelWaiters = []
    }

    func refreshToken() async -> String? { "refresh" }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { user }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
}
