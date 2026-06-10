import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// An ``AuthClient`` whose network phases can be parked on demand, so a test
/// can hold a round trip (the `/users/me` validation fetch, the team list, or
/// the credential exchange) in flight while other coordinator work (a
/// sign-out) runs, then release it. Mimics the live races where a request
/// departed before sign-out and resumes afterwards.
actor GateableValidationAuthClient: AuthClient {
    /// One park-on-demand gate: arming parks the next guarded call until
    /// released, and `didPark` lets the test await the parked state so it acts
    /// against work that is genuinely in flight rather than racing its start.
    /// Reference type so the actor's helper methods mutate the gate in place;
    /// it never escapes the actor.
    private final class Gate {
        var armed = false
        var parked: CheckedContinuation<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let user: CMUXAuthUser
    private let teams: [CMUXAuthTeam]
    private var access: String?
    private var refresh: String?
    private let validationGate = Gate()
    private let teamsGate = Gate()
    private let credentialGate = Gate()
    private let clearGate = Gate()

    init(user: CMUXAuthUser, teams: [CMUXAuthTeam] = []) {
        self.user = user
        self.teams = teams
    }

    // MARK: - Gate plumbing

    private func didPark(_ gate: Gate) async {
        if gate.parked != nil { return }
        await withCheckedContinuation { gate.waiters.append($0) }
    }

    private func release(_ gate: Gate) {
        gate.parked?.resume()
        gate.parked = nil
    }

    private func parkIfArmed(_ gate: Gate) async {
        guard gate.armed else { return }
        gate.armed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.parked = continuation
            for waiter in gate.waiters { waiter.resume() }
            gate.waiters = []
        }
    }

    // MARK: - Validation gate (the `/users/me` fetch)

    func armValidationGate() { validationGate.armed = true }
    func validationDidPark() async { await didPark(validationGate) }
    func releaseParkedValidation() { release(validationGate) }

    /// Script the gated `currentUser` fetch to throw once released, like an
    /// in-flight validation whose session was definitively rejected.
    func setGatedValidationError(_ error: any Error) { gatedValidationError = error }
    private var gatedValidationError: (any Error)?

    // MARK: - Teams gate (the publish path's team refresh)

    func armTeamsGate() { teamsGate.armed = true }
    func teamsDidPark() async { await didPark(teamsGate) }
    func releaseParkedTeams() { release(teamsGate) }

    // MARK: - Credential gate (the password sign-in exchange)

    func armCredentialGate() { credentialGate.armed = true }
    func credentialDidPark() async { await didPark(credentialGate) }
    func releaseParkedCredential() { release(credentialGate) }

    // MARK: - Clear gate (the local token-store clear)

    func armClearGate() { clearGate.armed = true }
    func clearDidPark() async { await didPark(clearGate) }
    func releaseParkedClear() { release(clearGate) }

    // MARK: - AuthClient

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        let wasGated = validationGate.armed
        await parkIfArmed(validationGate)
        if wasGated, let error = gatedValidationError {
            gatedValidationError = nil
            throw error
        }
        return user
    }

    func listTeams() async throws -> [CMUXAuthTeam] {
        await parkIfArmed(teamsGate)
        return teams
    }

    func signInWithCredential(email: String, password: String) async throws {
        await parkIfArmed(credentialGate)
        // The exchange stores fresh tokens when it resumes, even when a
        // sign-out cleared the store while the request was in flight.
        access = "access"
        refresh = "refresh"
    }

    func accessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async -> String? { access }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}

    func storedAccessToken() async -> String? { access }

    func clearLocalSession() async {
        await parkIfArmed(clearGate)
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}

    func mintAccessToken(refreshToken: String) async -> String? { nil }
}
