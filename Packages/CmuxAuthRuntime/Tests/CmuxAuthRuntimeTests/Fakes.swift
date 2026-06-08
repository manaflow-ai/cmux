import AuthenticationServices
import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

/// In-memory key-value store for deterministic cache tests.
final class FakeKeyValueStore: CMUXAuthKeyValueStore, @unchecked Sendable {
    // Single-threaded test usage; mutations happen on the test's main actor.
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool { storage[defaultName] as? Bool ?? false }
    func data(forKey defaultName: String) -> Data? { storage[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
}

/// Scriptable ``AuthClient`` recording calls and returning canned results.
actor FakeAuthClient: AuthClient {
    var access: String?
    var refresh: String?
    /// Result of ``forceRefreshAccessToken()``. When `nil` (the default), the
    /// fake returns the current ``access`` to preserve the original behavior;
    /// set it explicitly to script a force-refresh outcome independent of the
    /// normal access token.
    var forceRefreshResult: String??
    var user: CMUXAuthUser?
    var teams: [CMUXAuthTeam] = []
    var throwOnCurrentUser: (any Error)?
    var throwOnListTeams: (any Error)?
    var nonce = "nonce-123"
    private(set) var signedInWithMagicLink = false
    private(set) var signedInWithCredential: (email: String, password: String)?
    private(set) var oauthProviders: [String] = []
    private(set) var signOutCount = 0

    init(access: String? = nil, refresh: String? = nil, user: CMUXAuthUser? = nil) {
        self.access = access
        self.refresh = refresh
        self.user = user
    }

    func setUser(_ user: CMUXAuthUser?) { self.user = user }
    func setTokens(access: String?, refresh: String?) {
        self.access = access
        self.refresh = refresh
    }
    func setForceRefreshResult(_ result: String?) { forceRefreshResult = .some(result) }
    func setThrowOnCurrentUser(_ error: (any Error)?) { throwOnCurrentUser = error }
    func setTeams(_ teams: [CMUXAuthTeam]) { self.teams = teams }
    func setThrowOnListTeams(_ error: (any Error)?) { throwOnListTeams = error }

    func accessToken() async -> String? { access }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async -> String? {
        if case let .some(scripted) = forceRefreshResult {
            return scripted
        }
        return access
    }

    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        if let throwOnCurrentUser { throw throwOnCurrentUser }
        return user
    }

    func listTeams() async throws -> [CMUXAuthTeam] {
        if let throwOnListTeams { throw throwOnListTeams }
        return teams
    }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { nonce }

    func signInWithMagicLink(code: String) async throws {
        signedInWithMagicLink = true
        access = "access"
    }

    func signInWithCredential(email: String, password: String) async throws {
        signedInWithCredential = (email, password)
        access = "access"
    }

    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        oauthProviders.append(provider)
        access = "access"
    }

    func signOut() async throws {
        signOutCount += 1
        access = nil
        refresh = nil
    }
}

/// A no-op presentation anchor for OAuth flows in tests.
final class FakeAnchor: NSObject, AuthPresentationAnchoring {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

/// A sign-out hook latch for asserting the injected `onSignedOut` ran.
actor HookFlag {
    private(set) var fired = false
    func fire() { fired = true }
}

/// Captures a value observed inside an async hook, for ordering assertions.
actor TokenProbe {
    private(set) var value: String?
    func set(_ token: String?) { value = token }
}

/// Records the lifecycle of a sign-out teardown hook so a test can prove the
/// teardown is structured (joined + cancelled before sign-out returns) rather
/// than detached.
actor TeardownOutcomeProbe {
    private(set) var started = false
    private(set) var finished = false
    private(set) var cancelled = false
    func markStarted() { started = true }
    func markFinished() { finished = true }
    func markCancelled() { cancelled = true }
}

extension AuthLaunchOptions {
    static func plain(includesDevAuth: Bool = false) -> AuthLaunchOptions {
        AuthLaunchOptions(
            clearAuthRequested: false,
            mockDataEnabled: false,
            environment: [:],
            includesDevAuth: includesDevAuth
        )
    }
}

extension AuthConfig {
    static let test = AuthConfig(
        stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
        magicLinkCallbackURL: "http://localhost/auth/callback",
        apiBaseURL: "http://localhost"
    )
}
