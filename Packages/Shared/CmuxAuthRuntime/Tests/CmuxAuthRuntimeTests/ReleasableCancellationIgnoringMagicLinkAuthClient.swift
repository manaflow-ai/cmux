import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

actor ReleasableCancellationIgnoringMagicLinkAuthClient: AuthClient {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRelease = false
    private(set) var startCount = 0

    func waitForStartCount(_ count: Int) async {
        if startCount >= count { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        startCount += 1
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        while !didRelease {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return "nonce"
    }

    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
