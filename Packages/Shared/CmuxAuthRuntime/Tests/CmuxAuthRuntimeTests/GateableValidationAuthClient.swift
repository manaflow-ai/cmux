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
        var parked: [CheckedContinuation<Void, Never>] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let user: CMUXAuthUser
    private let teams: [CMUXAuthTeam]
    private var access: String?
    private var refresh: String?
    /// Each credential exchange mints a distinct session's tokens (like the
    /// live backend, where every exchange creates a new server-side session),
    /// so tests can tell WHICH exchange's write the store currently holds:
    /// exchange N stores `"access-N"` / `"refresh-N"` in write order.
    private var exchangeCounter = 0
    private let validationGate = Gate()
    private let teamsGate = Gate()
    private let credentialGate = Gate()
    private let clearGate = Gate()
    private let storedAccessGate = Gate()
    private var credentialExchangeIgnoresCancellation = false
    private(set) var credentialStartCount = 0
    private(set) var magicLinkStartCount = 0

    init(user: CMUXAuthUser, teams: [CMUXAuthTeam] = []) {
        self.user = user
        self.teams = teams
    }

    // MARK: - Gate plumbing

    private func didPark(_ gate: Gate, count: Int = 1) async {
        if gate.parked.count >= count { return }
        await withCheckedContinuation { gate.waiters.append((count, $0)) }
    }

    private func release(_ gate: Gate) {
        guard !gate.parked.isEmpty else { return }
        gate.parked.removeFirst().resume()
    }

    private func parkIfArmed(_ gate: Gate) async {
        guard gate.armed else { return }
        gate.armed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.parked.append(continuation)
            gate.waiters.removeAll { waiter in
                guard gate.parked.count >= waiter.count else { return false }
                waiter.continuation.resume()
                return true
            }
        }
    }

    // MARK: - Validation gate (the `/users/me` fetch)

    func armValidationGate() { validationGate.armed = true }
    func validationDidPark(count: Int = 1) async { await didPark(validationGate, count: count) }
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
    func setCredentialExchangeIgnoresCancellation(_ value: Bool) { credentialExchangeIgnoresCancellation = value }

    // MARK: - Stored access gate (sign-out credential capture)

    func armStoredAccessGate() { storedAccessGate.armed = true }
    func storedAccessDidPark() async { await didPark(storedAccessGate) }
    func releaseParkedStoredAccess() { release(storedAccessGate) }

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
        credentialStartCount += 1
        await parkIfArmed(credentialGate)
        // Mirror the vendored SDK's `publishSessionTokens` chokepoint: a flow
        // whose task was cancelled while the request was in flight must not
        // persist a session behind UI that already reported the flow as over.
        if !credentialExchangeIgnoresCancellation {
            try Task.checkCancellation()
        }
        // The exchange stores fresh tokens when it resumes, even when a
        // sign-out cleared the store while the request was in flight.
        exchangeCounter += 1
        access = "access-\(exchangeCounter)"
        refresh = "refresh-\(exchangeCounter)"
    }

    func accessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async -> String? { access }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {
        magicLinkStartCount += 1
        await parkIfArmed(credentialGate)
        try Task.checkCancellation()
        exchangeCounter += 1
        access = "access-\(exchangeCounter)"
        refresh = "refresh-\(exchangeCounter)"
    }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}

    func storedAccessToken() async -> String? {
        await parkIfArmed(storedAccessGate)
        return access
    }

    func clearLocalSession() async {
        await parkIfArmed(clearGate)
        access = nil
        refresh = nil
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        await parkIfArmed(clearGate)
        // The compare runs at execution time, like the token store's atomic
        // compareAndSet: a store that changed owners while this clear was
        // parked is left alone.
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}

    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
