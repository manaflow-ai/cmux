import CMUXAuthCore
import CMUXMobileCore
import Foundation
import Observation
import OSLog
import StackAuth

private let authLog = Logger(subsystem: "ai.manaflow.cmux.ios", category: "auth")

public enum MobileAuthBuildPolicy {
    public static var includesFortyTwoShortcut: Bool {
        #if CMUX_DEV_AUTH
        true
        #else
        false
        #endif
    }
}

enum MobileAuthAutoLoginPolicy {
    static func shouldStartAutoLogin(
        credentials: AuthAutoLoginCredentials?,
        hasStoredTokens: Bool
    ) -> Bool {
        credentials != nil && !hasStoredTokens
    }
}

@MainActor
@Observable
public final class AuthManager {
    public static let shared = AuthManager()

    public var isAuthenticated = false
    public var currentUser: StackAuthUser?
    public var isLoading = false
    public var isRestoringSession = false

    private let stack = StackAuthApp.shared
    private let authUserCache = AuthUserCache.shared
    private let authSessionCache = AuthSessionCache.shared
    private var pendingNonce: String?

    private init() {
        primeSessionState()
        Task {
            await checkExistingSession()
        }
    }

    private var clearAuthRequested: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_CLEAR_AUTH"] == "1"
    }

    private var autoLoginCredentials: AuthAutoLoginCredentials? {
        AuthLaunchConfig.autoLoginCredentials(
            from: ProcessInfo.processInfo.environment,
            clearAuth: clearAuthRequested,
            mockDataEnabled: UITestConfig.mockDataEnabled
        )
    }

    private var authFixtureUser: StackAuthUser? {
        AuthLaunchConfig.fixtureUser(
            from: ProcessInfo.processInfo.environment,
            clearAuth: clearAuthRequested,
            mockDataEnabled: UITestConfig.mockDataEnabled
        )
    }

    private func primeSessionState() {
        if clearAuthRequested {
            clearAuthState()
            Task {
                await clearPersistedAuthForUITest()
            }
            return
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: true,
                    fixtureUser: nil,
                    autoLoginCredentials: nil,
                    cachedUser: nil,
                    hasTokens: false,
                    mockUser: uiTestMockUser
                )
            )
            return
        }

        if let authFixtureUser {
            authLog.debug("Using auth fixture user")
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: false,
                    fixtureUser: authFixtureUser,
                    autoLoginCredentials: nil,
                    cachedUser: authFixtureUser,
                    hasTokens: true,
                    mockUser: uiTestMockUser
                )
            )
            return
        }

        if autoLoginCredentials != nil {
            authLog.debug("Auto-login credentials detected")
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: false,
                    fixtureUser: nil,
                    autoLoginCredentials: autoLoginCredentials,
                    cachedUser: authUserCache.load(),
                    hasTokens: authSessionCache.hasTokens,
                    mockUser: uiTestMockUser
                )
            )
            return
        }
        #endif

        applyAuthState(
            CMUXAuthState.primed(
                clearAuthRequested: false,
                mockDataEnabled: false,
                fixtureUser: nil,
                autoLoginCredentials: nil,
                cachedUser: authUserCache.load(),
                hasTokens: authSessionCache.hasTokens,
                mockUser: uiTestMockUser
            )
        )
    }

    private func checkExistingSession() async {
        if clearAuthRequested {
            return
        }

        let cachedUser = authUserCache.load()
        let hasAccessToken = await stack.getAccessToken() != nil
        let hasRefreshToken = await stack.getRefreshToken() != nil
        let hasStoredTokens = hasAccessToken || hasRefreshToken

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            return
        }

        if let fixtureUser = authFixtureUser {
            authLog.debug("Applying auth fixture user")
            authUserCache.save(fixtureUser)
            authSessionCache.setHasTokens(true)
            currentUser = fixtureUser
            isAuthenticated = true
            return
        }

        if let credentials = autoLoginCredentials,
           MobileAuthAutoLoginPolicy.shouldStartAutoLogin(
               credentials: credentials,
               hasStoredTokens: hasStoredTokens
           ) {
            authLog.debug("Starting auto-login for \(credentials.email, privacy: .private)")
            await performAutoLogin(credentials)
            return
        }
        #endif

        if hasStoredTokens {
            authSessionCache.setHasTokens(true)
            if currentUser == nil, let cachedUser {
                currentUser = cachedUser
            }
            await validateCachedSession(hasStoredTokens: hasStoredTokens)
            return
        }

        #if CMUX_DEV_AUTH
        if let creds = debugPasswordCredentials {
            authLog.debug("Auto-login with persisted debug credentials")
            await performAutoLogin(AuthAutoLoginCredentials(email: creds.email, password: creds.password))
            return
        }
        #endif

        clearAuthState()
    }

    private func performAutoLogin(_ credentials: AuthAutoLoginCredentials) async {
        do {
            try await signInWithPassword(email: credentials.email, password: credentials.password, setLoading: false)
        } catch {
            authLog.error("Auto-login failed: \(error.localizedDescription, privacy: .private)")
            await clearPersistedStackSession()
            clearAuthState()
        }
    }

    private func validateCachedSession(hasStoredTokens: Bool) async {
        do {
            if let user = try await stack.getUser(or: .throw) {
                await applySignedInUser(user)
                return
            }
            authLog.info("Cached session validation returned no current user")
            await clearPersistedStackSession()
            clearAuthState()
            return
        } catch {
            let action = Self.cachedSessionValidationFailureAction(for: error)
            authLog.error(
                "Session validation failed action=\(action.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            switch action {
            case .clearSession:
                await clearPersistedStackSession()
                clearAuthState()
            case .preserveCachedSession:
                preserveCachedSessionAfterValidationFailure()
            }
        }
    }

    private func applySignedInUser(_ user: CurrentUser) async {
        let mappedUser = await StackAuthUser(currentUser: user)
        await applySignedInUser(mappedUser)
    }

    private func applySignedInUser(_ mappedUser: StackAuthUser) async {
        currentUser = mappedUser
        isAuthenticated = true
        isRestoringSession = false
        authUserCache.save(mappedUser)
        authSessionCache.setHasTokens(true)
        await NotificationManager.shared.syncTokenIfPossible()
    }

    private func clearAuthState() {
        pendingNonce = nil
        authUserCache.clear()
        authSessionCache.clear()
        applyAuthState(.cleared())
    }

    private func preserveCachedSessionAfterValidationFailure() {
        authSessionCache.setHasTokens(true)
        let cachedUser = currentUser ?? authUserCache.load()
        currentUser = cachedUser
        isAuthenticated = cachedUser != nil
        isRestoringSession = false
    }

    private func clearPersistedAuthForUITest() async {
        #if CMUX_DEV_AUTH
        clearDebugPasswordCredentials()
        #endif
        await clearPersistedStackSession()
    }

    private func clearPersistedStackSession() async {
        do {
            try await stack.signOut()
        } catch {
            authLog.error("Stack token clear failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    #if CMUX_DEV_AUTH
    private struct DebugCredentials {
        let email: String
        let password: String
    }

    private var debugPasswordCredentials: DebugCredentials?

    private func clearDebugPasswordCredentials() {
        debugPasswordCredentials = nil
    }
    #endif

    public func sendCode(to email: String) async throws {
        try requireOnline()
        isLoading = true
        defer { isLoading = false }

        #if CMUX_DEV_AUTH
        if email.trimmingCharacters(in: .whitespacesAndNewlines) == "42" {
            let creds = DebugCredentials(email: "l@l.com", password: "abc123")
            try await signInWithPassword(email: creds.email, password: creds.password, setLoading: false)
            debugPasswordCredentials = creds
            return
        }
        #endif

        do {
            let nonce = try await stack.sendMagicLinkEmail(email: email, callbackUrl: AppEnvironment.current.magicLinkCallbackURL)
            pendingNonce = nonce
        } catch {
            throw sanitizedAuthError(error)
        }
    }

    public func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }
        try requireOnline()

        isLoading = true
        defer { isLoading = false }

        let fullCode = AuthMagicLinkCode.compose(code: code, nonce: nonce)
        do {
            try await stack.signInWithMagicLink(code: fullCode)
            try await completeSignIn()
        } catch {
            throw sanitizedAuthError(error)
        }

        pendingNonce = nil
    }

    public func signInWithPassword(email: String, password: String, setLoading: Bool = true) async throws {
        try requireOnline()
        if setLoading {
            isLoading = true
        }
        defer {
            if setLoading {
                isLoading = false
            }
        }

        do {
            try await stack.signInWithCredential(email: email, password: password)
            try await completeSignIn()
        } catch {
            throw sanitizedAuthError(error)
        }
    }

    public func signInWithApple() async throws {
        try requireOnline()
        isLoading = true
        defer { isLoading = false }

        do {
            try await stack.signInWithOAuth(
                provider: "apple",
                presentationContextProvider: AuthPresentationContextProvider.shared
            )
            try await completeSignIn()
        } catch {
            throw sanitizedAuthError(error)
        }
    }

    public func signInWithGoogle() async throws {
        try requireOnline()
        isLoading = true
        defer { isLoading = false }

        do {
            try await stack.signInWithOAuth(
                provider: "google",
                presentationContextProvider: AuthPresentationContextProvider.shared
            )
            try await completeSignIn()
        } catch {
            throw sanitizedAuthError(error)
        }
    }

    /// Fail fast with a clear offline error before starting a network sign-in,
    /// so the user gets immediate feedback instead of waiting for a request to
    /// time out (e.g. tapping a provider button with Wi-Fi off).
    private func requireOnline() throws {
        guard NetworkReachability.shared.isOnline else {
            throw AuthError.offline
        }
    }

    private func completeSignIn() async throws {
        guard let user = try await stack.getUser(or: .throw) else {
            throw AuthError.unauthorized
        }
        await applySignedInUser(user)
    }

    public func signOut() async {
        do {
            try await stack.signOut()
        } catch {
            authLog.error("Sign-out failed: \(error.localizedDescription, privacy: .private)")
        }

        #if CMUX_DEV_AUTH
        clearDebugPasswordCredentials()
        #endif
        clearAuthState()
        await NotificationManager.shared.unregisterFromServer()
    }

    public func getAccessToken() async throws -> String {
        if let accessToken = await stack.getAccessToken() {
            return accessToken
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            return "cmux-ui-test-stack-token"
        }
        #endif

        #if CMUX_DEV_AUTH
        if let credentials = debugPasswordCredentials {
            try? await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
            if let accessToken = await stack.getAccessToken() {
                return accessToken
            }
        }
        #endif

        // No usable access token. Distinguish recoverable from definitive so the
        // caller never signs the user out on a transient blip: if a refresh token
        // is still present, the SDK could not mint a fresh access token for a
        // network/server reason (it clears the refresh token only on a genuine
        // server rejection), so this is retryable. Only a missing refresh token
        // means the session is truly gone and a real re-sign-in is required.
        if await stack.getRefreshToken() != nil {
            throw AuthError.networkError
        }
        throw AuthError.unauthorized
    }

    /// The current Stack refresh token, if any. Native API calls authenticate
    /// with `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`,
    /// so callers need both this and ``getAccessToken()``.
    public func getRefreshToken() async -> String? {
        await stack.getRefreshToken()
    }

    /// Force-mint a fresh access token, bypassing the cached-token freshness
    /// check. Call this after the host rejected the current token so the retry
    /// presents a genuinely new credential instead of the same rejected one.
    ///
    /// The SDK serializes refreshes per token store through its refresh lock, so
    /// concurrent callers (e.g. several in-flight RPCs when the token tips over)
    /// never overlap a refresh exchange. Note this serializes rather than
    /// coalesces: each waiter still performs its own exchange in turn against the
    /// non-rotating refresh token.
    ///
    /// - Returns: a freshly minted access token.
    /// - Throws: ``AuthError/networkError`` when the refresh failed transiently
    ///   but the session is intact (a refresh token is still stored), so the
    ///   caller should retry rather than sign out; ``AuthError/unauthorized``
    ///   only when the session is genuinely gone (the refresh token was
    ///   definitively rejected and cleared).
    @discardableResult
    public func forceRefreshAccessToken() async throws -> String {
        if let accessToken = await stack.fetchNewAccessToken() {
            return accessToken
        }

        // Same classification as `getAccessToken()`: a surviving refresh token
        // means the failure was transient (network/server), so stay retryable;
        // a missing one means the SDK definitively cleared the session.
        if await stack.getRefreshToken() != nil {
            throw AuthError.networkError
        }
        throw AuthError.unauthorized
    }

    private func sanitizedAuthError(_ error: Error) -> Error {
        Self.displaySafeAuthError(error)
    }

    public nonisolated static func displaySafeAuthError(_ error: Error) -> Error {
        if let authError = error as? AuthError {
            return authError
        }
        if let stackError = error as? StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "OAUTH_CANCELLED":
                return AuthError.cancelled
            case
                "SCHEMA_ERROR",
                "USER_EMAIL_ALREADY_EXISTS",
                "VERIFICATION_CODE_ERROR",
                "INVALID_OTP",
                "OTP_EXPIRED",
                "RATE_LIMIT",
                "EMAIL_PASSWORD_MISMATCH",
                "USER_NOT_FOUND",
                "PASSKEY_AUTHENTICATION_FAILED",
                "PASSKEY_WEBAUTHN_ERROR",
                "INVALID_TOTP_CODE",
                "REDIRECT_URL_NOT_WHITELISTED",
                "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN",
                "INVALID_APPLE_CREDENTIALS":
                return error
            case "UNAUTHORIZED", "INVALID_TOKEN", "TOKEN_EXPIRED":
                return AuthError.unauthorized
            default:
                return AuthError.serverError(0, "auth_failed")
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return AuthError.networkError
        }
        return AuthError.serverError(0, "auth_failed")
    }

    public nonisolated static func cachedSessionValidationFailureAction(
        for error: Error
    ) -> CachedSessionValidationFailureAction {
        let safeError = displaySafeAuthError(error)
        if case AuthError.unauthorized = safeError {
            return .clearSession
        }
        return .preserveCachedSession
    }
}

public enum CachedSessionValidationFailureAction: String, Equatable, Sendable {
    case clearSession
    case preserveCachedSession
}

private extension AuthManager {
    var uiTestMockUser: StackAuthUser {
        StackAuthUser(
            id: "uitest_user",
            primaryEmail: "uitest@cmux.local",
            displayName: "UI Test"
        )
    }

    func applyAuthState(_ state: CMUXAuthState) {
        currentUser = state.currentUser
        isAuthenticated = state.isAuthenticated
        isRestoringSession = state.isRestoringSession
    }
}

typealias AuthAutoLoginCredentials = CMUXAuthAutoLoginCredentials

enum AuthLaunchConfig {
    static func autoLoginCredentials(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> AuthAutoLoginCredentials? {
        CMUXAuthLaunchConfig.autoLoginCredentials(
            from: environment,
            clearAuth: clearAuth,
            mockDataEnabled: mockDataEnabled
        )
    }

    static func fixtureUser(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> StackAuthUser? {
        CMUXAuthLaunchConfig.fixtureUser(
            from: environment,
            clearAuth: clearAuth,
            mockDataEnabled: mockDataEnabled
        ).map { StackAuthUser(id: $0.id, primaryEmail: $0.primaryEmail, displayName: $0.displayName) }
    }
}

enum AuthMagicLinkCode {
    static func compose(code: String, nonce: String) -> String {
        CMUXAuthMagicLinkCode.compose(code: code, nonce: nonce)
    }
}

@MainActor
final class AuthSessionCache {
    static let shared = AuthSessionCache()
    private let cache = CMUXAuthSessionCache(
        keyValueStore: UserDefaults.standard,
        key: "auth_has_tokens"
    )

    private init() {}

    var hasTokens: Bool {
        cache.hasTokens
    }

    func setHasTokens(_ value: Bool) {
        cache.setHasTokens(value)
    }

    func clear() {
        cache.clear()
    }
}

@MainActor
final class AuthUserCache {
    static let shared = AuthUserCache()
    private let store = CMUXAuthIdentityStore(
        keyValueStore: UserDefaults.standard,
        key: "auth_cached_user"
    )

    private init() {}

    func save(_ user: StackAuthUser) {
        do {
            try store.save(user)
        } catch {
            authLog.error("Failed to cache user: \(error.localizedDescription, privacy: .private)")
        }
    }

    func load() -> StackAuthUser? {
        do {
            return try store.load()
        } catch {
            authLog.error("Failed to load cached user: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func clear() {
        store.clear()
    }
}
