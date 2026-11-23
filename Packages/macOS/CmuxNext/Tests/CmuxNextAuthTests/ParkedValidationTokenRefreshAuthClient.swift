import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

actor ParkedValidationTokenRefreshAuthClient: AuthClient {
    private let user: CMUXAuthUser
    private var access: String? = "old-access"
    private var refresh: String? = "old-refresh"
    private var staleValidationAccess = "stale-validation-access"
    private var staleValidationRefresh = "stale-validation-refresh"
    private var shouldParkValidation = true
    private var compareClearGateArmed = false
    private var parked: CheckedContinuation<Void, Never>?
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var compareClearParked: CheckedContinuation<Void, Never>?
    private var compareClearWaiters: [CheckedContinuation<Void, Never>] = []
    private var credentialWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var credentialDidWrite = false
    private var credentialCurrentUserGateArmed = false
    private var credentialCurrentUserParked: CheckedContinuation<Void, Never>?
    private var credentialCurrentUserWaiters: [CheckedContinuation<Void, Never>] = []

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func validationDidPark() async {
        if parked != nil { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func releaseValidationWithStaleTokenWrite() {
        parked?.resume()
        parked = nil
    }

    func compareClearDidPark() async {
        if compareClearParked != nil { return }
        await withCheckedContinuation { compareClearWaiters.append($0) }
    }

    func releaseCompareClear() {
        compareClearParked?.resume()
        compareClearParked = nil
    }

    func credentialWriteDidHappen() async {
        if credentialDidWrite { return }
        await withCheckedContinuation { credentialWriteWaiters.append($0) }
    }

    func credentialCurrentUserDidPark() async {
        if credentialCurrentUserParked != nil { return }
        await withCheckedContinuation { credentialCurrentUserWaiters.append($0) }
    }

    func armCompareClearGate() {
        compareClearGateArmed = true
    }

    func armCredentialCurrentUserGate() {
        credentialCurrentUserGateArmed = true
    }

    func setStaleValidationWrite(access: String, refresh: String) {
        staleValidationAccess = access
        staleValidationRefresh = refresh
    }

    func releaseCredentialCurrentUser() {
        credentialCurrentUserParked?.resume()
        credentialCurrentUserParked = nil
    }

    func accessToken() async -> String? {
        access
    }

    func refreshToken() async -> String? {
        refresh
    }

    func forceRefreshAccessToken() async -> String? {
        access
    }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if shouldParkValidation {
            shouldParkValidation = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked = continuation
                let waiters = parkWaiters
                parkWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
            access = staleValidationAccess
            refresh = staleValidationRefresh
            return user
        }
        if credentialCurrentUserGateArmed {
            credentialCurrentUserGateArmed = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                credentialCurrentUserParked = continuation
                let waiters = credentialCurrentUserWaiters
                credentialCurrentUserWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return user
    }

    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {
        access = "new-access"
        refresh = "new-refresh"
        credentialDidWrite = true
        let waiters = credentialWriteWaiters
        credentialWriteWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { access }

    func clearLocalSession() async {
        access = nil
        refresh = nil
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        if compareClearGateArmed {
            compareClearGateArmed = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                compareClearParked = continuation
                let waiters = compareClearWaiters
                compareClearWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        guard self.refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
