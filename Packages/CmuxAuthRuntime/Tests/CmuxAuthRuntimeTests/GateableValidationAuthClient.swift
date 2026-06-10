import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose `currentUser` fetch can be parked on demand, so a
/// test can hold a session-revalidation round trip in flight while other
/// coordinator work (a sign-out) runs, then release it. Mimics the live race
/// where the request departed with valid tokens before sign-out destroyed
/// them, so it still resumes with a signed-in user.
actor GateableValidationAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private let teams: [CMUXAuthTeam]
    private var access: String?
    private var refresh: String?
    private var gateArmed = false
    private var parkedValidation: CheckedContinuation<Void, Never>?
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var teamsGateArmed = false
    private var parkedTeams: CheckedContinuation<Void, Never>?
    private var teamsParkWaiters: [CheckedContinuation<Void, Never>] = []

    init(user: CMUXAuthUser, teams: [CMUXAuthTeam] = []) {
        self.user = user
        self.teams = teams
    }

    /// Park the next `currentUser` fetch until ``releaseParkedValidation()``.
    func armValidationGate() {
        gateArmed = true
    }

    /// Suspends until the gated `currentUser` fetch is parked, so the test
    /// acts against a validation that is genuinely in flight rather than
    /// racing its start.
    func validationDidPark() async {
        if parkedValidation != nil { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    /// Resume the parked fetch; it completes with the signed-in user, like an
    /// in-flight request that authenticated before the local tokens vanished.
    func releaseParkedValidation() {
        parkedValidation?.resume()
        parkedValidation = nil
    }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if gateArmed {
            gateArmed = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedValidation = continuation
                for waiter in parkWaiters { waiter.resume() }
                parkWaiters = []
            }
        }
        return user
    }

    /// Park the next `listTeams` fetch until ``releaseParkedTeams()``, so a
    /// test can hold the publish path inside its team refresh (the await that
    /// follows the signed-in state writes) while a sign-out runs.
    func armTeamsGate() {
        teamsGateArmed = true
    }

    /// Suspends until the gated `listTeams` fetch is parked.
    func teamsDidPark() async {
        if parkedTeams != nil { return }
        await withCheckedContinuation { teamsParkWaiters.append($0) }
    }

    /// Resume the parked team fetch; it completes with the configured teams.
    func releaseParkedTeams() {
        parkedTeams?.resume()
        parkedTeams = nil
    }

    func accessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async -> String? { access }

    func listTeams() async throws -> [CMUXAuthTeam] {
        if teamsGateArmed {
            teamsGateArmed = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedTeams = continuation
                for waiter in teamsParkWaiters { waiter.resume() }
                teamsParkWaiters = []
            }
        }
        return teams
    }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}

    func signInWithCredential(email: String, password: String) async throws {
        access = "access"
        refresh = "refresh"
    }

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}

    func storedAccessToken() async -> String? { access }

    func clearLocalSession() async {
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}

    func mintAccessToken(refreshToken: String) async -> String? { nil }
}
