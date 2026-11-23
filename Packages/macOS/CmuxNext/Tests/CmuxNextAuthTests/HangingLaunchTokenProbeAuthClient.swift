import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

actor HangingLaunchTokenProbeAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var accessStartCount = 0

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func accessTokenDidStart() async {
        await waitForAccessStartCount(1)
    }

    func waitForAccessStartCount(_ count: Int) async {
        if accessStartCount >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func releaseHangingAccessTokenProbe() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }

    func accessToken() async -> String? {
        accessStartCount += 1
        startWaiters.removeAll { waiter in
            guard accessStartCount >= waiter.count else { return false }
            waiter.continuation.resume()
            return true
        }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return nil
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
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
}
