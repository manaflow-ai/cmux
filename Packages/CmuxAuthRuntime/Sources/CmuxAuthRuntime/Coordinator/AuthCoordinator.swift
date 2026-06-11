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
///     teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "auth_selected_team"),
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
    /// The teams the signed-in user belongs to (refreshed on sign-in/restore).
    public private(set) var availableTeams: [CMUXAuthTeam] = []
    /// The user's selected team id. Writes persist through the injected
    /// ``CMUXAuthCore/CMUXAuthTeamSelectionStore``.
    public var selectedTeamID: String? {
        didSet {
            guard selectedTeamID != oldValue else { return }
            teamSelection.selectedTeamID = selectedTeamID
        }
    }

    /// The team id API calls should target: the persisted selection while it is
    /// still one of ``availableTeams``, else the first available team.
    public var resolvedTeamID: String? {
        Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: availableTeams)
    }

    private let client: any AuthClient
    private let sessionCache: CMUXAuthSessionCache
    private let userCache: CMUXAuthIdentityStore
    private let teamSelection: CMUXAuthTeamSelectionStore
    private let anchor: any AuthPresentationAnchoring
    private let config: AuthConfig
    private let launch: AuthLaunchOptions
    private let timeouts: AuthTimeouts
    private let clock: any Clock<Duration>
    private let isOnline: @Sendable () async -> Bool
    private let onSignedIn: @Sendable () async -> Void
    private let log = AuthDebugLog()

    private var pendingNonce: String?
    private var debugCredentials: CMUXAuthAutoLoginCredentials?
    private var bootstrapTask: Task<Void, Never>?
    private var isRevalidatingSession = false
    /// Monotonic session epoch, advanced by every session transition: each
    /// ``clearAuthState()`` AND each published sign-in
    /// (``applySignedInUser(_:)``). Flows that touch session state after
    /// suspension points (launch restore, foreground revalidation, sign-in
    /// completion) capture it at entry and drop their writes when it has
    /// moved on: local-first sign-out clears state up front with no trailing
    /// clear, so a sign-out that lands while such a flow is parked in a
    /// network call must win instead of being overwritten by the stale
    /// result; conversely a stale validation failure must not wipe a newer
    /// session, including one published with no clear in between. Same
    /// pattern as `HostBrowserSignInFlow.signOutGeneration`.
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    /// Monotonic sign-in attempt count, allocating each flow's attempt id.
    @ObservationIgnored private var signInAttemptCounter: UInt64 = 0
    /// The highest attempt id whose credential exchange has written the token
    /// store (recorded when the flow reaches its completion step, immediately
    /// after the exchange's write). The last writer owns the store: a stale
    /// attempt's rollback (clearing the tokens its resuming exchange
    /// re-stored after a sign-out) may only run while no NEWER attempt has
    /// written, so a newer in-flight attempt's tokens survive even before it
    /// publishes, while a newer attempt that failed before writing does not
    /// block the cleanup.
    @ObservationIgnored private var tokenStoreWriteHighWater: UInt64 = 0
    /// In-flight credential-exchange tasks by attempt id, registered by
    /// ``runExchange(_:flow:timeout:_:)`` so ``signOut(onSignedOut:teardownTimeout:)``
    /// can cancel them. The vendored SDK's token-write chokepoint
    /// (`publishSessionTokens`) refuses to persist tokens once its flow task
    /// is cancelled, so a cancelled exchange can never re-store credentials
    /// behind sign-out's local clear, no matter when its network call resumes.
    @ObservationIgnored private var activeSignInExchanges: [UInt64: Task<Void, any Error>] = [:]

    /// The staleness context a sign-in flow captures before its first await:
    /// the session generation (does a later sign-out invalidate this flow?)
    /// and the attempt number (is this flow still the token store's owner?).
    private struct SignInFlowContext {
        let generation: UInt64
        let attempt: UInt64
    }

    /// Begin a sign-in flow: register it as the newest attempt and capture
    /// the staleness context. Call before the flow's first await.
    private func beginSignInFlow() -> SignInFlowContext {
        signInAttemptCounter &+= 1
        return SignInFlowContext(generation: sessionGeneration, attempt: signInAttemptCounter)
    }

    /// Run a sign-in flow's credential exchange as a coordinator-owned child
    /// task registered under the flow's attempt id, racing the phase deadline
    /// like ``runPhase(_:timeout:_:)``.
    ///
    /// The registration is what makes sign-out able to win against a parked
    /// exchange: ``signOut(onSignedOut:teardownTimeout:)`` cancels every
    /// registered exchange before clearing local state, and the SDK's write
    /// chokepoint drops the token store write of a cancelled flow, so the
    /// stale exchange can neither resurrect the signed-out session nor
    /// clobber a newer sign-in's freshly written tokens. Caller cancellation
    /// is forwarded to the child task.
    private func runExchange(
        _ phase: AuthPhase,
        flow: SignInFlowContext,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let exchange = Task { try await self.runPhase(phase, timeout: timeout, operation) }
        activeSignInExchanges[flow.attempt] = exchange
        defer { activeSignInExchanges[flow.attempt] = nil }
        try await withTaskCancellationHandler {
            try await exchange.value
        } onCancel: {
            exchange.cancel()
        }
    }

    /// Creates an auth coordinator.
    ///
    /// - Parameters:
    ///   - client: The auth backend seam (production: ``StackAuthClient``).
    ///   - sessionCache: Persists the "has tokens" flag (injected key-value store).
    ///   - userCache: Persists the cached user (injected key-value store).
    ///   - teamSelection: Persists the selected team id (injected key-value store).
    ///   - anchor: Presentation anchor provider for OAuth flows.
    ///   - config: Resolved auth configuration (callback URL, project, API base).
    ///   - launch: Launch-time priming inputs (UI-test fixtures, dev-auth flag).
    ///   - timeouts: Per-phase deadlines for the sign-in/session flows. Every
    ///     phase that holds a loading state is bounded so the UI can never spin
    ///     forever; a phase that hits its deadline fails with the localized,
    ///     retryable ``AuthError/timedOut``. Defaults to ``AuthTimeouts/default``.
    ///   - clock: The clock the phase deadlines sleep on. Injected so tests
    ///     drive timeouts with virtual time. Defaults to `ContinuousClock`.
    ///   - isOnline: Connectivity probe; sign-in flows fail fast when offline.
    ///     Defaults to always-online so tests need not supply it.
    ///   - onSignedIn: Hook run after a successful sign-in / session restore, for
    ///     side effects above this package (e.g. push token re-upload). Defaults
    ///     to a no-op.
    public init(
        client: any AuthClient,
        sessionCache: CMUXAuthSessionCache,
        userCache: CMUXAuthIdentityStore,
        teamSelection: CMUXAuthTeamSelectionStore,
        anchor: any AuthPresentationAnchoring,
        config: AuthConfig,
        launch: AuthLaunchOptions,
        timeouts: AuthTimeouts = .default,
        clock: any Clock<Duration> = ContinuousClock(),
        isOnline: @escaping @Sendable () async -> Bool = { true },
        onSignedIn: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.sessionCache = sessionCache
        self.userCache = userCache
        self.teamSelection = teamSelection
        self.anchor = anchor
        self.config = config
        self.launch = launch
        self.timeouts = timeouts
        self.clock = clock
        self.isOnline = isOnline
        self.onSignedIn = onSignedIn
        self.selectedTeamID = teamSelection.selectedTeamID
        primeSessionState()
    }

    /// Begin asynchronous session restore. Call once after construction at the
    /// composition root. Idempotent priming already ran in `init`, and repeat
    /// calls are no-ops.
    public func start() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { await checkExistingSession() }
    }

    /// Await the launch session restore started by ``start()``. Returns
    /// immediately once restore has finished (or when ``start()`` was never
    /// called).
    ///
    /// Any probe that needs a definitive ``isAuthenticated`` value (socket
    /// `auth.status`, CLI-facing checks, token reads racing app launch) must
    /// await this first, otherwise it can observe the transient signed-out
    /// state while stored tokens are still being validated.
    public func awaitBootstrapped() async {
        await bootstrapTask?.value
    }

    /// Re-validate the persisted session against the live token store.
    ///
    /// Call this when the app returns to the foreground so a session that died
    /// while backgrounded (the SDK definitively rejected the refresh token, or
    /// the keychain was cleared) routes to the sign-in page on resume instead of
    /// surfacing a stale signed-in shell that fails at connect time. Reuses the
    /// same live-store probe as launch restore, which ends in
    /// ``clearAuthState()`` when no usable token remains and otherwise preserves
    /// the cached session on transient failures. Re-entrant calls (e.g. two
    /// rapid foreground transitions) coalesce: a second call while one is in
    /// flight returns immediately.
    public func revalidateSession() async {
        await checkExistingSession()
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
        // Coalesce overlapping runs (rapid foreground transitions): a second
        // call while one is in flight would race coordinator-state writes
        // (one run clearing while another re-validates the same stale token).
        if isRevalidatingSession { return }
        isRevalidatingSession = true
        defer { isRevalidatingSession = false }
        let generation = sessionGeneration
        let storeWriteHighWater = tokenStoreWriteHighWater

        let cachedUser = loadCachedUser()
        // accessToken() may refresh over the network; a sign-out can land
        // while these reads are parked, so re-check the generation after.
        let hasAccessToken = await client.accessToken() != nil
        let hasRefreshToken = await client.refreshToken() != nil
        guard generation == sessionGeneration else { return }
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
            await performAutoLogin(credentials, generation: generation, storeWriteHighWater: storeWriteHighWater)
            return
        }
        #endif

        if hasStoredTokens {
            sessionCache.setHasTokens(true)
            if currentUser == nil, let cachedUser {
                currentUser = cachedUser
            }
            await validateCachedSession(generation: generation, storeWriteHighWater: storeWriteHighWater)
            return
        }

        if launch.includesDevAuth, let creds = debugCredentials {
            authLog.debug("Auto-login with persisted debug credentials")
            await performAutoLogin(creds, generation: generation, storeWriteHighWater: storeWriteHighWater)
            return
        }

        clearAuthState()
    }

    /// Run the launch/dev auto-login, capturing the same staleness context as
    /// the validation flows (`generation` / `storeWriteHighWater` from the
    /// caller's entry) so its failure cleanup cannot wipe a session
    /// established after the auto-login began.
    private func performAutoLogin(
        _ credentials: CMUXAuthAutoLoginCredentials,
        generation: UInt64,
        storeWriteHighWater: UInt64
    ) async {
        do {
            try await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
        } catch {
            // A cancellation means a competing session transition won:
            // sign-out cancelled this auto-login's exchange, or a newer
            // sign-in/clear bumped the epoch and the completion dropped
            // itself. The winner owns all session state; clearing here would
            // wipe the NEWER session, not the failed auto-login.
            if error is CancellationError || (error as? AuthError) == .cancelled {
                authLog.info("Auto-login superseded by a newer session transition; leaving state untouched")
                return
            }
            authLog.error("Auto-login failed: \(error.localizedDescription, privacy: .private)")
            await clearStaleSessionState(generation: generation, storeWriteHighWater: storeWriteHighWater)
        }
    }

    private func validateCachedSession(generation: UInt64, storeWriteHighWater: UInt64) async {
        do {
            let client = self.client
            let user = try await runPhase(.validateSession, timeout: timeouts.network) {
                try await client.currentUser(throwOnMissing: true)
            }
            // A sign-out landed while the fetch was in flight: the user's
            // later intent wins. Drop the stale result instead of
            // republishing a session whose local tokens are already gone.
            guard generation == sessionGeneration else { return }
            if let user {
                await applySignedInUser(user)
                return
            }
            authLog.info("Cached session validation returned no current user")
            await clearStaleSessionState(generation: generation, storeWriteHighWater: storeWriteHighWater)
        } catch {
            // Same staleness rule for the failure paths: a stale clear here
            // could wipe a session established after this flow began.
            guard generation == sessionGeneration else { return }
            // Drive the clear-vs-preserve decision from LIVE session validity, not
            // the error code alone. The SDK throws the same `UserNotSignedInError`
            // ("USER_NOT_SIGNED_IN") for two opposite situations: a genuine
            // definitive rejection (the refresh token was 400/401'd and the SDK
            // deleted it from the store) and a transient `/users/me` failure (the
            // SDK's getUser swallows network/server errors into the same "no user"
            // path). The error code cannot tell them apart, so the code-based
            // decision would preserve a session whose tokens are already
            // gone — exactly the stale "signed in" shell that then fails at connect
            // time with a confusing host-side message. The live token store is the
            // ground truth: if no refresh token survives, the session is genuinely
            // gone and the user must see the sign-in page.
            let refreshTokenSurvives = await client.refreshToken() != nil
            guard generation == sessionGeneration else { return }
            if !refreshTokenSurvives {
                authLog.error(
                    "Session validation failed and no refresh token survives; routing to login error=\(error.localizedDescription, privacy: .private)"
                )
                await clearStaleSessionState(generation: generation, storeWriteHighWater: storeWriteHighWater)
                return
            }
            let action = AuthError(displaySafe: error)?.cachedSessionValidationFailureAction
                ?? .preserveCachedSession
            authLog.error(
                "Session validation failed action=\(action.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            switch action {
            case .clearSession:
                await clearStaleSessionState(generation: generation, storeWriteHighWater: storeWriteHighWater)
            case .preserveCachedSession:
                preserveCachedSessionAfterValidationFailure()
            }
        }
    }

    /// Clear the persisted token store and published auth state on behalf of
    /// a validation flow that captured `generation` and `storeWriteHighWater`
    /// at entry, re-checking staleness around the suspension points.
    ///
    /// When a newer sign-in exchange has written the store since the flow
    /// began, the store has a new in-flight owner and the failed validation
    /// of the OLD session must touch nothing at all: clearing the store
    /// would wipe the new owner's tokens, and clearing the published state
    /// would bump the epoch and spuriously cancel the in-flight sign-in
    /// while leaving its tokens orphaned for the next launch restore. The
    /// published-state clear also re-checks both markers after the awaited
    /// store clear, so a session transition landing inside that suspension
    /// is not unpublished by the stale failure. Residual: a store clear
    /// already executing when a faster sign-in writes cannot be unwound from
    /// here; that would need a compare-and-clear inside the token store
    /// itself, and the exposure is a single keychain write.
    private func clearStaleSessionState(generation: UInt64, storeWriteHighWater: UInt64) async {
        guard tokenStoreWriteHighWater == storeWriteHighWater else { return }
        await clearPersistedStackSession()
        guard generation == sessionGeneration,
              tokenStoreWriteHighWater == storeWriteHighWater else { return }
        clearAuthState()
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
            let client = self.client
            let callbackURL = config.magicLinkCallbackURL
            let nonce = try await runPhase(.sendCode, timeout: timeouts.network) {
                try await client.sendMagicLinkEmail(email: email, callbackURL: callbackURL)
            }
            pendingNonce = nonce
        } catch {
            throw AuthError(displaySafe: error) ?? error
        }
    }

    /// Verify a magic-link code against the pending nonce.
    public func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }
        // Captured before the first await so a sign-out landing anywhere in
        // this flow (connectivity probe, exchange, user fetch) wins.
        let flow = beginSignInFlow()
        try await requireOnline()
        isLoading = true
        defer { isLoading = false }

        let fullCode = CMUXAuthMagicLinkCode(code: code, nonce: nonce).composed
        do {
            let client = self.client
            try await runExchange(.verifyCode, flow: flow, timeout: timeouts.network) {
                try await client.signInWithMagicLink(code: fullCode)
            }
            try await completeSignIn(flow: flow)
        } catch {
            throw AuthError(displaySafe: error) ?? error
        }
        pendingNonce = nil
    }

    /// Sign in with an email/password credential.
    public func signInWithPassword(email: String, password: String, setLoading: Bool = true) async throws {
        // Captured before the first await so a sign-out landing anywhere in
        // this flow (connectivity probe, exchange, user fetch) wins.
        let flow = beginSignInFlow()
        try await requireOnline()
        if setLoading { isLoading = true }
        defer { if setLoading { isLoading = false } }

        do {
            let client = self.client
            try await runExchange(.passwordSignIn, flow: flow, timeout: timeouts.network) {
                try await client.signInWithCredential(email: email, password: password)
            }
            try await completeSignIn(flow: flow)
        } catch {
            throw AuthError(displaySafe: error) ?? error
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
        // Captured before the first await so a sign-out landing anywhere in
        // this flow (connectivity probe, OAuth exchange, user fetch) wins.
        let flow = beginSignInFlow()
        try await requireOnline()
        isLoading = true
        defer { isLoading = false }
        do {
            // Interactive deadline: ASAuthorizationController (Sign in with
            // Apple) and ASWebAuthenticationSession callbacks are not
            // guaranteed to fire; without a bound a stuck system sheet left
            // the sign-in screen loading forever with no error and no way out.
            let client = self.client
            let anchor = self.anchor
            try await runExchange(.oauth, flow: flow, timeout: timeouts.interactiveFlow) {
                try await client.signInWithOAuth(provider: provider, anchor: anchor)
            }
            try await completeSignIn(flow: flow)
        } catch {
            log.log("auth.oauth provider=\(provider) failed: \(error)")
            throw AuthError(displaySafe: error) ?? error
        }
    }

    /// - Parameter flow: The context captured at the public sign-in
    ///   entrypoint, before the credential exchange's first await, so a
    ///   sign-out landing anywhere in the flow wins (not only during the
    ///   final user fetch).
    private func completeSignIn(flow: SignInFlowContext) async throws {
        // This flow's credential exchange (or external seeding) just wrote
        // the token store; record it as the store's latest known writer.
        tokenStoreWriteHighWater = max(tokenStoreWriteHighWater, flow.attempt)
        // A sign-out landed during the credential exchange that ran before
        // this completion. The resuming exchange re-stored fresh tokens that
        // the sign-out's clear never saw, so drop those too: otherwise the
        // next launch restore resurrects the session the user just signed out
        // of. The rollback only runs while no NEWER attempt has written the
        // token store and nothing newer has published: a newer attempt owns
        // the store from the moment its exchange writes (even before it
        // publishes), and clearing here would wipe its tokens; a newer
        // attempt that failed before writing does not block the cleanup.
        // The race surfaces as a cancellation (the sign-in UI treats
        // `.cancelled` as a deliberate back-out, not a failure).
        //
        // This rollback is the second line of defense: sign-out also CANCELS
        // every registered in-flight exchange (see `runExchange`), and the
        // SDK's write chokepoint drops a cancelled flow's store write, so a
        // stale exchange normally never re-stores tokens at all. The
        // rollback covers a write that already raced past the chokepoint
        // when the cancellation landed.
        //
        // Residual, accepted: the high-water mark advances when a flow
        // resumes on this actor, not atomically with the SDK's internal
        // store write, so two interactive sign-in exchanges racing within
        // one scheduler hop (no sign-out involved) can still mis-order
        // ownership. Interactive sign-ins are serialized by the UI (one
        // sign-in screen, one attempt); making this airtight needs
        // coordinator-serialized attempts (cancel-previous, like
        // HostBrowserSignInFlow's cancelActiveAttempt) or a compare-and-swap
        // token store, both follow-up territory.
        guard flow.generation == sessionGeneration else {
            if !isAuthenticated && tokenStoreWriteHighWater == flow.attempt {
                await client.clearLocalSession()
            }
            throw CancellationError()
        }
        let client = self.client
        let user = try await runPhase(.fetchUser, timeout: timeouts.network) {
            try await client.currentUser(throwOnMissing: true)
        }
        guard let user else {
            throw AuthError.unauthorized
        }
        // A sign-out landed during the user fetch instead: the exchange's
        // tokens were already in the store when sign-out cleared it, so
        // nothing lingers; only the publish must be dropped.
        guard flow.generation == sessionGeneration else {
            throw CancellationError()
        }
        await applySignedInUser(user)
    }

    /// Complete a sign-in whose credentials were established outside the
    /// ``AuthClient`` seam, e.g. the macOS hosted-browser flow that seeds the
    /// auth-callback tokens directly into the injected token store.
    ///
    /// Validates the now-stored session and publishes the signed-in state
    /// (user, caches, teams, the `onSignedIn` hook).
    /// - Throws: ``AuthError/unauthorized`` when no signed-in user could be
    ///   fetched with the seeded tokens; other display-safe errors otherwise.
    public func completeExternalSignIn() async throws {
        // The credentials were seeded before this call, so the capture here
        // covers the validation round trip; the seeding flow keeps its own
        // sign-out race guard for the seeded tokens.
        let flow = beginSignInFlow()
        isLoading = true
        defer { isLoading = false }
        do {
            try await completeSignIn(flow: flow)
        } catch {
            throw AuthError(displaySafe: error) ?? error
        }
    }

    /// Sign out, local-first: the device ends signed out immediately, with the
    /// server-side teardown a bounded best-effort tail.
    ///
    /// Local session state (tokens, cached user, team selection, the published
    /// signed-in flags) is cleared before any network I/O, so sign-out behaves
    /// identically with no connectivity. Offline, the Stack revocation DELETE
    /// neither completes nor fails promptly; sign-out used to await it before
    /// clearing anything, leaving the user stuck signed in. The credentials the
    /// server-side teardown needs are captured with raw stored reads (no
    /// network) before the clear.
    ///
    /// Security tradeoff, chosen deliberately: when the teardown deadline fires
    /// (offline, dead server), the server-side session is NOT revoked, so the
    /// refresh token stays valid server-side until it expires or is revoked
    /// elsewhere. The device's copy is destroyed by the local clear, so using
    /// it requires having exfiltrated it beforehand. The alternative (blocking
    /// sign-out on revocation) leaves a user who wants out stuck signed in,
    /// which is the worse failure for a device about to change hands.
    ///
    /// - Parameter onSignedOut: An async hook the composition root uses to run
    ///   token-authenticated teardown (e.g. deleting the APNs device token from
    ///   the server) that lives above this package. It receives the
    ///   access/refresh tokens captured before the local clear (the access
    ///   token freshly minted from the captured refresh token when the store
    ///   was refresh-only), because by the time it runs the live token store
    ///   is already empty; it runs before the Stack session revocation so the
    ///   server still honors those credentials. Defaults to a no-op.
    /// - Parameter teardownTimeout: How long the best-effort server teardown
    ///   (hook + revocation) may run before it is cancelled so a hanging call
    ///   can't hold `signOut()` open. Sleeps on the injected clock so tests
    ///   drive the deadline with virtual time. Defaults to 5 seconds.
    public func signOut(
        onSignedOut: @escaping @Sendable (_ accessToken: String?, _ refreshToken: String?) async -> Void = { _, _ in },
        teardownTimeout: Duration = .seconds(5)
    ) async {
        // Cancel in-flight sign-in exchanges FIRST: the SDK's token-write
        // chokepoint refuses to store after cancellation, so a parked
        // exchange can never re-store credentials behind this sign-out's
        // local clear, no matter when its network call resumes. Cancel and
        // go, deliberately not awaiting the cancelled exchanges: joining
        // them here would block local-first sign-out on their unwinding
        // (the rollback in `completeSignIn` stays as belt-and-braces for a
        // write that already raced past the chokepoint).
        for exchange in activeSignInExchanges.values { exchange.cancel() }

        // Mark the sign-out epoch synchronously, before the first await
        // below, so a sign-in completion whose exchange write already raced
        // past the cancellation chokepoint and which interleaves with the
        // awaited reads/clear sees a stale epoch and takes its rollback path
        // instead of publishing over this sign-out. clearAuthState() bumps
        // again afterwards; epochs only need to be monotonic.
        sessionGeneration &+= 1

        // Capture the teardown credentials with raw stored reads (no refresh,
        // no network) before they are destroyed.
        let accessToken = await client.storedAccessToken()
        let refreshToken = await client.refreshToken()

        // LOCAL-FIRST: clear everything local before any network I/O. From
        // here the device is signed out no matter what the network does.
        await client.clearLocalSession()
        if launch.includesDevAuth { debugCredentials = nil }
        clearAuthState()

        // Best-effort bounded server-side teardown with the captured tokens:
        // the hook first (the push-token DELETE needs the session to still be
        // valid server-side), then the Stack session revocation. STRUCTURED:
        // on deadline the group cancels and joins the work child, so it can
        // never outlive sign-out and interleave with a later sign-in. Both
        // legs run on URLSession (cancellation-aware), so the join is prompt.
        let client = self.client
        let clock = self.clock
        let log = self.log
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // The raw capture can hold an expired access token (the SDK
                // leaves stale ones stored while a valid refresh survives) or
                // none at all on a refresh-only store. Run the captured pair
                // through the refresh-aware ephemeral credential path so the
                // teardown presents a usable Bearer: the captured token when
                // still fresh, else one minted from the captured refresh,
                // never touching the cleared live store. Best-effort and
                // cancellation-aware (URLSession) like the rest of the tail.
                var teardownAccessToken = accessToken
                if let refreshToken {
                    teardownAccessToken = await client.freshAccessToken(
                        accessToken: accessToken,
                        refreshToken: refreshToken
                    ) ?? accessToken
                }
                await onSignedOut(teardownAccessToken, refreshToken)
                guard !Task.isCancelled else {
                    log.log("auth.signOut teardown deadline hit before revocation; server session left unrevoked")
                    return
                }
                do {
                    try await client.revokeSession(accessToken: teardownAccessToken, refreshToken: refreshToken)
                } catch {
                    // Best-effort by design; see the security tradeoff above.
                    authLog.error("Sign-out session revocation failed: \(error.localizedDescription, privacy: .private)")
                    log.log("auth.signOut revocation failed: \(error)")
                }
            }
            group.addTask {
                // Bounded, cancellable teardown deadline (carve-out); the loser
                // is cancelled by `cancelAll()` once the first side finishes.
                try? await clock.sleep(for: teardownTimeout, tolerance: nil)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Tokens

    /// The current access token.
    ///
    /// Classifies a missing token the same way ``forceRefreshAccessToken()``
    /// does, so the connection layer can tell a recoverable session from a dead
    /// one: when the SDK could not hand back an access token but a refresh token
    /// is still stored, the failure was transient (network/server) and this
    /// throws ``AuthError/networkError`` so the caller retries without signing
    /// out. When neither token survives, the session is genuinely gone, so this
    /// calls ``clearAuthState()`` (flipping ``isAuthenticated`` to `false`, which
    /// routes the root scene to the sign-in page) and throws
    /// ``AuthError/unauthorized``.
    /// - Returns: A current access token.
    /// - Throws: ``AuthError/networkError`` on a transient failure with a
    ///   surviving refresh token (retryable); ``AuthError/unauthorized`` once the
    ///   session is definitively gone (also clears local auth state).
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
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session and the user must sign in again.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        clearAuthState()
        throw AuthError.unauthorized
    }

    /// The current refresh token, if any. Native API calls authenticate with
    /// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`.
    public func refreshToken() async -> String? {
        await client.refreshToken()
    }

    /// Both tokens for the current session, for callers that talk to
    /// cmux-owned backend endpoints (e.g. the cloud VM service) with the
    /// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`
    /// header pair.
    ///
    /// Awaits the launch restore first: RPCs firing before the restore
    /// finishes could otherwise observe an empty token store on a
    /// refresh-token-only start and report "Not signed in" even though a valid
    /// session becomes available moments later.
    /// - Returns: The access and refresh tokens.
    /// - Throws: ``AuthError/unauthorized`` when either token is missing.
    public func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        await awaitBootstrapped()
        guard let access = await client.accessToken(), !access.isEmpty else {
            throw AuthError.unauthorized
        }
        guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
            throw AuthError.unauthorized
        }
        return (access, refresh)
    }

    /// Force-mint a fresh access token, bypassing the cached-token freshness
    /// check. Call this after the host rejected the current token so the retry
    /// presents a genuinely new credential instead of the same rejected one.
    ///
    /// - Returns: A freshly minted access token.
    /// - Throws: ``AuthError/networkError`` when the refresh failed transiently
    ///   but the session is intact (a refresh token is still stored), so the
    ///   caller should retry rather than sign out; ``AuthError/unauthorized``
    ///   only when the session is genuinely gone (the refresh token was
    ///   definitively rejected and cleared). The definitive case also calls
    ///   ``clearAuthState()`` so ``isAuthenticated`` flips to `false` and the
    ///   root scene routes to the sign-in page instead of showing a stale shell.
    public func forceRefreshAccessToken() async throws -> String {
        if let token = await client.forceRefreshAccessToken() {
            return token
        }
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        clearAuthState()
        throw AuthError.unauthorized
    }

    // MARK: - State helpers

    private func applySignedInUser(_ user: CMUXAuthUser) async {
        // Publishing a session advances the epoch exactly like clearing one:
        // any other flow that captured the pre-publish generation (a stale
        // revalidation of the previous session still parked in its fetch)
        // must not clear or overwrite this newer session when it resumes.
        sessionGeneration &+= 1
        let generation = sessionGeneration
        currentUser = user
        isAuthenticated = true
        isRestoringSession = false
        saveCachedUser(user)
        sessionCache.setHasTokens(true)
        await refreshTeams(generation: generation)
        // A sign-out landed during the team refresh: the flags above were
        // already cleared by it, so skip the signed-in side effects (push
        // token re-upload would re-register the account the user just left).
        guard generation == sessionGeneration else { return }
        // Bound the post-sign-in hook (e.g. push token re-upload) too: it runs
        // while `isLoading` is still true, so an unbounded hook would hold the
        // sign-in spinner after the session is already published. Failure and
        // timeout are tolerated; the hook is a side effect, not a gate.
        let onSignedIn = self.onSignedIn
        _ = try? await runPhase(.postSignIn, timeout: timeouts.network) {
            await onSignedIn()
        }
    }

    /// Refresh ``availableTeams`` from the client, tolerating failure so a
    /// flaky team fetch never blocks or unwinds a successful sign-in. Drops
    /// the writes when a sign-out raced the fetch, so a signed-out shell does
    /// not get the old account's teams persisted back.
    private func refreshTeams(generation: UInt64) async {
        do {
            let client = self.client
            let teams = try await runPhase(.listTeams, timeout: timeouts.network) {
                try await client.listTeams()
            }
            guard generation == sessionGeneration else { return }
            availableTeams = teams
            selectedTeamID = Self.resolveTeamID(selectedTeamID: selectedTeamID, teams: teams)
        } catch {
            authLog.error("Failed to list teams: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func resolveTeamID(
        selectedTeamID: String?,
        teams: [CMUXAuthTeam]
    ) -> String? {
        if let selectedTeamID,
           teams.contains(where: { $0.id == selectedTeamID }) {
            return selectedTeamID
        }
        return teams.first?.id
    }

    private func clearAuthState() {
        sessionGeneration &+= 1
        pendingNonce = nil
        userCache.clear()
        sessionCache.clear()
        availableTeams = []
        selectedTeamID = nil
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

    /// Clear the locally persisted Stack session, with no server round trip.
    ///
    /// Used on restore/validation paths where the session is already dead or
    /// unusable (definitive refresh-token rejection, vanished user, failed
    /// auto-login, UI-test resets). These paths previously ran the SDK's
    /// network sign-out, whose revocation DELETE can block for minutes offline
    /// and wedge launch restore; revoking an already-dead session buys
    /// nothing, so they clear locally only. Interactive sign-out
    /// (``signOut(onSignedOut:teardownTimeout:)``) still attempts a bounded
    /// best-effort revocation.
    private func clearPersistedStackSession() async {
        await client.clearLocalSession()
    }

    private func requireOnline() async throws {
        guard await isOnline() else {
            throw AuthError.offline
        }
    }

    /// Race `operation` against the phase deadline on the injected clock.
    /// See ``withAuthPhaseTimeout(_:duration:clock:log:operation:)``.
    private func runPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withAuthPhaseTimeout(
            phase,
            duration: timeout,
            clock: clock,
            log: log,
            operation: operation
        )
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
        CMUXAuthAutoLoginCredentials(
            environment: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
    }

    private var fixtureUser: CMUXAuthUser? {
        CMUXAuthUser(
            uiTestFixtureEnvironment: launch.environment,
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
