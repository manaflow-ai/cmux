public import CMUXAuthCore
import Foundation
public import Observation
import OSLog

private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

/// The shared, injected auth orchestrator for cmux.
///
/// Owns the observable session state (``isAuthenticated`` / ``currentUser`` /
/// ``isLoading`` / ``isRestoringSession``) and sequences every sign-in flow plus
/// session restore/validation. Replaces the iOS `AuthManager.shared` singleton
/// (and is intended to replace the macOS `ObservableObject` AuthManager too).
///
/// Construct it once at the app composition root with an injected
/// ``AuthClient``, persistence stores, presentation anchor, config, and launch
/// options, then inject it into the UI as `@Environment`:
///
/// ```swift
/// let coordinator = AuthCoordinator(
///     client: StackAuthClient(config: config, tokenStore: .keychain),
///     sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "auth_has_tokens"),
///     userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "auth_cached_user"),
///     anchor: AuthPresentationContextProvider(),
///     config: config,
///     launch: launchOptions
/// )
/// coordinator.start()
/// ```
@MainActor
@Observable
public final class AuthCoordinator {
    /// Whether a user session is currently active.
    public private(set) var isAuthenticated = false
    /// The signed-in user, if any.
    public private(set) var currentUser: CMUXAuthUser?
    /// Whether an interactive sign-in flow is in flight (drives spinners).
    public private(set) var isLoading = false
    /// Whether a cached session is being restored/validated at launch.
    public private(set) var isRestoringSession = false

    private let client: any AuthClient
    private let sessionCache: CMUXAuthSessionCache
    private let userCache: CMUXAuthIdentityStore
    private let anchor: any AuthPresentationAnchoring
    private let config: AuthConfig
    private let launch: AuthLaunchOptions
    private let isOnline: @Sendable () async -> Bool
    private let errorMapper = AuthErrorMapper()

    private var pendingNonce: String?
    private var debugCredentials: CMUXAuthAutoLoginCredentials?

    /// Creates an auth coordinator.
    ///
    /// - Parameters:
    ///   - client: The auth backend seam (production: ``StackAuthClient``).
    ///   - sessionCache: Persists the "has tokens" flag (injected key-value store).
    ///   - userCache: Persists the cached user (injected key-value store).
    ///   - anchor: Presentation anchor provider for OAuth flows.
    ///   - config: Resolved auth configuration (callback URL, project, API base).
    ///   - launch: Launch-time priming inputs (UI-test fixtures, dev-auth flag).
    ///   - isOnline: Connectivity probe; sign-in flows fail fast when offline.
    ///     Defaults to always-online so tests need not supply it.
    public init(
        client: any AuthClient,
        sessionCache: CMUXAuthSessionCache,
        userCache: CMUXAuthIdentityStore,
        anchor: any AuthPresentationAnchoring,
        config: AuthConfig,
        launch: AuthLaunchOptions,
        isOnline: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.client = client
        self.sessionCache = sessionCache
        self.userCache = userCache
        self.anchor = anchor
        self.config = config
        self.launch = launch
        self.isOnline = isOnline
        primeSessionState()
    }

    /// Begin asynchronous session restore. Call once after construction at the
    /// composition root. Idempotent priming already ran in `init`.
    public func start() {
        Task { await checkExistingSession() }
    }

    // MARK: - Priming

    private func primeSessionState() {
        if launch.clearAuthRequested {
            clearAuthState()
            Task { await clearPersistedAuthForUITest() }
            return
        }

        #if DEBUG
        if launch.mockDataEnabled {
            apply(.primed(
                clearAuthRequested: false,
                mockDataEnabled: true,
                fixtureUser: nil,
                autoLoginCredentials: nil,
                cachedUser: nil,
                hasTokens: false,
                mockUser: Self.uiTestMockUser
            ))
            return
        }

        if let fixtureUser {
            authLog.debug("Using auth fixture user")
            apply(.primed(
                clearAuthRequested: false,
                mockDataEnabled: false,
                fixtureUser: fixtureUser,
                autoLoginCredentials: nil,
                cachedUser: fixtureUser,
                hasTokens: true,
                mockUser: Self.uiTestMockUser
            ))
            return
        }

        if autoLoginCredentials != nil {
            authLog.debug("Auto-login credentials detected")
            apply(.primed(
                clearAuthRequested: false,
                mockDataEnabled: false,
                fixtureUser: nil,
                autoLoginCredentials: autoLoginCredentials,
                cachedUser: loadCachedUser(),
                hasTokens: sessionCache.hasTokens,
                mockUser: Self.uiTestMockUser
            ))
            return
        }
        #endif

        apply(.primed(
            clearAuthRequested: false,
            mockDataEnabled: false,
            fixtureUser: nil,
            autoLoginCredentials: nil,
            cachedUser: loadCachedUser(),
            hasTokens: sessionCache.hasTokens,
            mockUser: Self.uiTestMockUser
        ))
    }

    private func checkExistingSession() async {
        if launch.clearAuthRequested { return }

        let cachedUser = loadCachedUser()
        let hasAccessToken = await client.accessToken() != nil
        let hasRefreshToken = await client.refreshToken() != nil
        let hasStoredTokens = hasAccessToken || hasRefreshToken

        #if DEBUG
        if launch.mockDataEnabled { return }

        if let fixtureUser {
            authLog.debug("Applying auth fixture user")
            saveCachedUser(fixtureUser)
            sessionCache.setHasTokens(true)
            currentUser = fixtureUser
            isAuthenticated = true
            return
        }

        if let credentials = autoLoginCredentials,
           AuthLaunchOptions.shouldStartAutoLogin(
               hasCredentials: true,
               hasStoredTokens: hasStoredTokens
           ),
           credentials.email.isEmpty == false {
            authLog.debug("Starting auto-login")
            await performAutoLogin(credentials)
            return
        }
        #endif

        if hasStoredTokens {
            sessionCache.setHasTokens(true)
            if currentUser == nil, let cachedUser {
                currentUser = cachedUser
            }
            await validateCachedSession()
            return
        }

        if launch.includesDevAuth, let creds = debugCredentials {
            authLog.debug("Auto-login with persisted debug credentials")
            await performAutoLogin(creds)
            return
        }

        clearAuthState()
    }

    private func performAutoLogin(_ credentials: CMUXAuthAutoLoginCredentials) async {
        do {
            try await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
        } catch {
            authLog.error("Auto-login failed: \(error.localizedDescription, privacy: .private)")
            await clearPersistedStackSession()
            clearAuthState()
        }
    }

    private func validateCachedSession() async {
        do {
            if let user = try await client.currentUser(throwOnMissing: true) {
                await applySignedInUser(user)
                return
            }
            authLog.info("Cached session validation returned no current user")
            await clearPersistedStackSession()
            clearAuthState()
        } catch {
            let action = errorMapper.cachedSessionValidationFailureAction(for: error)
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

    // MARK: - Sign-in flows

    /// Send a sign-in code to `email`, or run the debug `42` shortcut.
    public func sendCode(to email: String) async throws {
        try await requireOnline()
        isLoading = true
        defer { isLoading = false }

        if launch.includesDevAuth,
           email.trimmingCharacters(in: .whitespacesAndNewlines) == "42" {
            let creds = CMUXAuthAutoLoginCredentials(email: "l@l.com", password: "abc123")
            try await signInWithPassword(email: creds.email, password: creds.password, setLoading: false)
            debugCredentials = creds
            return
        }

        do {
            let nonce = try await client.sendMagicLinkEmail(
                email: email,
                callbackURL: config.magicLinkCallbackURL
            )
            pendingNonce = nonce
        } catch {
            throw errorMapper.displaySafe(error)
        }
    }

    /// Verify a magic-link code against the pending nonce.
    public func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }
        try await requireOnline()
        isLoading = true
        defer { isLoading = false }

        let fullCode = CMUXAuthMagicLinkCode.compose(code: code, nonce: nonce)
        do {
            try await client.signInWithMagicLink(code: fullCode)
            try await completeSignIn()
        } catch {
            throw errorMapper.displaySafe(error)
        }
        pendingNonce = nil
    }

    /// Sign in with an email/password credential.
    public func signInWithPassword(email: String, password: String, setLoading: Bool = true) async throws {
        try await requireOnline()
        if setLoading { isLoading = true }
        defer { if setLoading { isLoading = false } }

        do {
            try await client.signInWithCredential(email: email, password: password)
            try await completeSignIn()
        } catch {
            throw errorMapper.displaySafe(error)
        }
    }

    /// Sign in with Apple.
    public func signInWithApple() async throws {
        try await signInWithOAuth(provider: "apple")
    }

    /// Sign in with Google.
    public func signInWithGoogle() async throws {
        try await signInWithOAuth(provider: "google")
    }

    private func signInWithOAuth(provider: String) async throws {
        try await requireOnline()
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.signInWithOAuth(provider: provider, anchor: anchor)
            try await completeSignIn()
        } catch {
            throw errorMapper.displaySafe(error)
        }
    }

    private func completeSignIn() async throws {
        guard let user = try await client.currentUser(throwOnMissing: true) else {
            throw AuthError.unauthorized
        }
        await applySignedInUser(user)
    }

    /// Sign out and clear local + persisted session state.
    ///
    /// - Parameter onSignedOut: An async hook the composition root uses to run
    ///   post-sign-out side effects (e.g. push unregistration) that live above
    ///   this package. Defaults to a no-op.
    public func signOut(onSignedOut: @Sendable () async -> Void = {}) async {
        do {
            try await client.signOut()
        } catch {
            authLog.error("Sign-out failed: \(error.localizedDescription, privacy: .private)")
        }
        if launch.includesDevAuth { debugCredentials = nil }
        clearAuthState()
        await onSignedOut()
    }

    // MARK: - Tokens

    /// The current access token, or throw ``AuthError/unauthorized`` if none.
    public func accessToken() async throws -> String {
        if let token = await client.accessToken() {
            return token
        }
        #if DEBUG
        if launch.mockDataEnabled {
            return "cmux-ui-test-stack-token"
        }
        #endif
        if launch.includesDevAuth, let credentials = debugCredentials {
            try? await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
            if let token = await client.accessToken() {
                return token
            }
        }
        throw AuthError.unauthorized
    }

    /// The current refresh token, if any. Native API calls authenticate with
    /// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`.
    public func refreshToken() async -> String? {
        await client.refreshToken()
    }

    // MARK: - State helpers

    private func applySignedInUser(_ user: CMUXAuthUser) async {
        currentUser = user
        isAuthenticated = true
        isRestoringSession = false
        saveCachedUser(user)
        sessionCache.setHasTokens(true)
    }

    private func clearAuthState() {
        pendingNonce = nil
        userCache.clear()
        sessionCache.clear()
        apply(.cleared())
    }

    private func preserveCachedSessionAfterValidationFailure() {
        sessionCache.setHasTokens(true)
        let cachedUser = currentUser ?? loadCachedUser()
        currentUser = cachedUser
        isAuthenticated = cachedUser != nil
        isRestoringSession = false
    }

    private func clearPersistedAuthForUITest() async {
        if launch.includesDevAuth { debugCredentials = nil }
        await clearPersistedStackSession()
    }

    private func clearPersistedStackSession() async {
        do {
            try await client.signOut()
        } catch {
            authLog.error("Stack token clear failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func requireOnline() async throws {
        guard await isOnline() else {
            throw AuthError.offline
        }
    }

    private func apply(_ state: CMUXAuthState) {
        currentUser = state.currentUser
        isAuthenticated = state.isAuthenticated
        isRestoringSession = state.isRestoringSession
    }

    private func loadCachedUser() -> CMUXAuthUser? {
        do {
            return try userCache.load()
        } catch {
            authLog.error("Failed to load cached user: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func saveCachedUser(_ user: CMUXAuthUser) {
        do {
            try userCache.save(user)
        } catch {
            authLog.error("Failed to cache user: \(error.localizedDescription, privacy: .private)")
        }
    }

    private var autoLoginCredentials: CMUXAuthAutoLoginCredentials? {
        CMUXAuthLaunchConfig.autoLoginCredentials(
            from: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
    }

    private var fixtureUser: CMUXAuthUser? {
        CMUXAuthLaunchConfig.fixtureUser(
            from: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
    }

    private static let uiTestMockUser = CMUXAuthUser(
        id: "uitest_user",
        primaryEmail: "uitest@cmux.local",
        displayName: "UI Test"
    )
}
