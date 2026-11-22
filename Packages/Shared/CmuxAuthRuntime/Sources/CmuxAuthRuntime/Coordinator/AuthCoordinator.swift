public import CMUXAuthCore
public import Foundation
public import Observation
import OSLog
import StackAuth

private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

/// The shared, injected auth orchestrator for cmux.
///
/// Owns the observable session state (``isAuthenticated`` / ``currentUser`` /
/// ``isLoading`` / ``isRestoringSession``). What happens next in every sign-in
/// flow, session restore, team refresh and sign-out is decided by the Rust
/// reducer behind ``AuthReducerEngine`` (cmux-tui/crates/cmux-auth-coordinator);
/// this class runs the effects it asks for (token store, network, caches,
/// clocks) and feeds their answers back.
///
/// Construct it once at the app composition root, then inject it into the UI
/// as `@Environment`:
///
/// ```swift
/// let coordinator = AuthCoordinator(
///     client: StackAuthClient(config: config, tokenStore: .keychain),
///     sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "auth_has_tokens"),
///     userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "auth_cached_user"),
///     teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "auth_selected_team"),
///     anchor: AuthPresentationContextProvider(),
///     config: config,
///     launch: launchOptions,
///     reducer: AuthReducerFFI.factory
/// )
/// coordinator.start()
/// ```
@MainActor
@Observable
public final class AuthCoordinator {
    /// Whether a user session is currently active.
    public internal(set) var isAuthenticated = false
    /// The signed-in user, if any.
    public internal(set) var currentUser: CMUXAuthUser?
    /// Whether an interactive sign-in flow is in flight (drives spinners).
    public internal(set) var isLoading = false
    /// Whether a cached session is being restored/validated at launch.
    public internal(set) var isRestoringSession = false
    /// Token-free detail (code, HTTP status, request ID) of the raw error that
    /// failed the last ``completeExternalSignIn()``, captured before the error
    /// collapses to a display-safe ``AuthError``.
    public internal(set) var lastExternalSignInFailureDetail: String?
    /// The teams the signed-in user belongs to (refreshed on sign-in/restore).
    public internal(set) var availableTeams: [CMUXAuthTeam] = [] {
        didSet {
            guard !isMirroring, availableTeams != oldValue else { return }
            feed(["availableTeamsSet": AuthWire(encoding: availableTeams)])
        }
    }
    /// The user's selected team id. Writes persist through the injected
    /// ``CMUXAuthCore/CMUXAuthTeamSelectionStore``.
    public var selectedTeamID: String? {
        didSet {
            guard !isMirroring, selectedTeamID != oldValue else { return }
            feed(["setSelectedTeam": AuthWire(selectedTeamID)])
        }
    }

    /// The team id API calls should target. While the team refresh is unavailable
    /// or still loading, the account-scoped persisted selection remains effective;
    /// once teams load, an invalid selection falls back to the first team.
    public var resolvedTeamID: String? { snapshot.resolvedTeamId }

    var apiBaseURL: String { config.apiBaseURL }

    let client: any AuthClient
    let sessionCache: CMUXAuthSessionCache
    let userCache: CMUXAuthIdentityStore
    let teamSelection: CMUXAuthTeamSelectionStore
    let anchor: any AuthPresentationAnchoring
    let config: AuthConfig
    let launch: AuthLaunchOptions
    let timeouts: AuthTimeouts
    let clock: any Clock<Duration>
    let isOnline: @Sendable () async -> Bool
    /// Reports whether the persisted token store is currently readable. On iOS the data-protection keychain is unreadable before the first unlock after boot (background push launch, prewarm); an empty token read while unavailable must be treated as transient, never as a signed-out verdict.
    let isTokenStorageAvailable: @Sendable () async -> Bool
    let onSessionWillTransition: @MainActor @Sendable () -> Void
    let onSignedIn: @Sendable () async -> Void
    let log = AuthDebugLog()
    /// Reports sign-in service 429s of the sign-in and session-check flows.
    @ObservationIgnored public let rateLimitTelemetry: StackRateLimitTelemetry

    /// The reducer and what it published after the last event.
    @ObservationIgnored let engine: any AuthReducerEngine
    @ObservationIgnored var snapshot: AuthReducerSnapshot
    @ObservationIgnored var isDraining = false
    @ObservationIgnored var isMirroring = false

    @ObservationIgnored var pendingNonce: String?
    @ObservationIgnored var debugCredentials: CMUXAuthAutoLoginCredentials?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var latestSignInRefreshToken: String?
    @ObservationIgnored var exchangeRecordedRefreshToken = false
    @ObservationIgnored var lastLocalClear: Task<Void, Never>?
    @ObservationIgnored var lastRateLimit: AuthRateLimit?

    // Restore: the in-flight run and the answers its later steps reuse.
    @ObservationIgnored var restoreInFlight = false
    @ObservationIgnored var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var restoreReadBaselines: [UInt64: TokenReadBaseline] = [:]
    @ObservationIgnored var survivingRefreshTokens: [UInt64: String] = [:]
    @ObservationIgnored var teamScopeRecoveryTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored var lastTeamRefresh: Task<Void, Never>?

    // Sign-in: the caller waiting on each attempt, and its raw error.
    @ObservationIgnored var requestedSignIn: PendingSignIn?
    @ObservationIgnored var signIns: [UInt64: PendingSignIn] = [:]
    @ObservationIgnored var signInErrors: [UInt64: any Error] = [:]

    // Sign-out and token reads.
    // A sign-out the reducer has not yet numbered, each numbered one by its
    // epoch, and the epoch whose local-clear answer is being fed (the
    // teardown effects it queues carry none).
    @ObservationIgnored var requestedSignOut: PendingSignOut?
    @ObservationIgnored var pendingSignOuts: [UInt64: PendingSignOut] = [:]
    @ObservationIgnored var answeringSignOutEpoch: UInt64?
    @ObservationIgnored var tokenReadFailure: AuthError?
    @ObservationIgnored var tokenReadTriesDevAuth = false

    @ObservationIgnored var authenticatedSessionIdentityContinuations: [
        UUID: AsyncStream<AuthenticatedSessionIdentity?>.Continuation
    ] = [:]
    @ObservationIgnored var authenticatedTeamScopeContinuations: [
        UUID: AsyncStream<AuthenticatedTeamScope?>.Continuation
    ] = [:]
    // Phase runs: each live run's task by its reducer id, and the reducer's
    // answers for the run being started or settled.
    @ObservationIgnored var phaseWork: [UInt64: AuthTrackedTokenWork] = [:]
    @ObservationIgnored var phaseStart: AuthPhaseStart?
    @ObservationIgnored var phaseSteps: [UInt64: String] = [:]
    /// Bumped by a team switch or create: a team-list read that started
    /// before one must not put the old selection back.
    @ObservationIgnored var teamMutationGeneration: UInt64 = 0 {
        didSet { feed("teamSelectionMutated") }
    }
    /// Bumped by a team delete or rename: a team-list read that started
    /// before one answers with the list it changed.
    @ObservationIgnored var teamListGeneration: UInt64 = 0 {
        didSet { feed("teamListMutated") }
    }
    /// Whether a team switch is still waiting on its server request.
    public internal(set) var isSelectingTeam = false
    /// Whether a team create is still waiting on its server request.
    public internal(set) var isCreatingTeam = false
    /// Whether a team delete is still waiting on its server request (and its fallback selection).
    public internal(set) var isDeletingTeam = false
    @ObservationIgnored var activeTeamSwitches: Set<UUID> = []
    @ObservationIgnored var isCapturingSignOutCredentials = false
    @ObservationIgnored var signOutCredentialCaptureWaiters: [CheckedContinuation<Void, Never>] = []

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
    ///   - timeouts: Per-phase deadlines; a phase that hits its deadline fails
    ///     with the retryable ``AuthError/timedOut``.
    ///   - clock: The clock the phase deadlines sleep on (virtual in tests).
    ///   - isOnline: Connectivity probe; sign-in flows fail fast when offline.
    ///   - isTokenStorageAvailable: Reports whether the persisted token store is currently readable. On iOS the data-protection keychain is unreadable before the first unlock after boot (background push launch, prewarm); an empty token read while unavailable must be treated as transient, never as a signed-out verdict.
    ///   - onSessionWillTransition: Synchronous hook invoked before the
    ///     coordinator advances to a different auth-session generation.
    ///   - onSignedIn: Hook run after a successful sign-in / session restore.
    ///   - rateLimitTelemetry: Receives sign-in service 429 records.
    ///   - reducer: Makes the Rust reducer from its config JSON: the Mac app
    ///     passes its C ABI binding, the iPhone app its UniFFI one.
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
        isTokenStorageAvailable: @escaping @Sendable () async -> Bool = { true },
        onSessionWillTransition: @escaping @MainActor @Sendable () -> Void = {},
        onSignedIn: @escaping @Sendable () async -> Void = {},
        rateLimitTelemetry: StackRateLimitTelemetry = .shared,
        reducer: AuthReducerFactory
    ) {
        self.client = client
        self.rateLimitTelemetry = rateLimitTelemetry
        self.sessionCache = sessionCache
        self.userCache = userCache
        self.teamSelection = teamSelection
        self.anchor = anchor
        self.config = config
        self.launch = launch
        self.timeouts = timeouts
        self.clock = clock
        self.isOnline = isOnline
        self.isTokenStorageAvailable = isTokenStorageAvailable
        self.onSessionWillTransition = onSessionWillTransition
        self.onSignedIn = onSignedIn
        let reducerConfig = Self.reducerConfig(
            launch: launch,
            cachedUser: Self.loadCachedUser(userCache),
            hasTokens: sessionCache.hasTokens,
            selectedTeamID: teamSelection.selectedTeamID
        )
        // A reducer that refuses the config leaves the app signed out (and logged),
        // never crashed: every event then fails the same way in ``feed(_:)``.
        let made = (try? JSONEncoder().encode(reducerConfig)).flatMap { try? reducer($0) }
        if made == nil { authLog.error("auth: the reducer refused its config; staying signed out") }
        engine = made ?? RefusedAuthReducer()
        snapshot = (made.flatMap { try? JSONDecoder().decode(AuthReducerSnapshot.self, from: $0.snapshot()) }) ?? .signedOut
        // The reducer primed the session from its config; its first effects
        // (clears the launch asked for) are already queued.
        drain()
    }

    /// Begin asynchronous session restore. Call once after construction at the
    /// composition root; repeat calls are no-ops.
    public func start() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { await restore("launch") }
    }

    /// Await the launch session restore started by ``start()``. Returns
    /// immediately once restore has finished (or when ``start()`` was never
    /// called).
    ///
    /// Any probe that needs a definitive ``isAuthenticated`` value must await
    /// this first, otherwise it can observe the transient signed-out state
    /// while stored tokens are still being validated.
    public func awaitBootstrapped() async {
        await bootstrapTask?.value
    }

    /// Re-validate the persisted session against the live token store.
    ///
    /// Call this on foreground so a session that died while backgrounded routes
    /// to sign-in on resume instead of surfacing a stale shell. A fully
    /// signed-out foreground return is a no-op; re-entrant calls coalesce.
    public func revalidateSession() async {
        await restore("foreground")
    }

    /// Supersede parked timed-out auth phases before an explicit interactive
    /// attempt (a pairing attempt, a tapped retry), so one hung Stack call does
    /// not fail the next user action for 30s. Live operations keep their
    /// exclusivity.
    public func supersedeTimedOutAuthPhases() async {
        feed("supersedeTimedOutPhases")
    }

    /// Starts (or joins) a session restore and returns once it finishes.
    func restore(_ trigger: AuthWire) async {
        feed(["restore": trigger])
        guard restoreInFlight else { return }
        await withCheckedContinuation { continuation in
            guard restoreInFlight else { return continuation.resume() }
            restoreWaiters.append(continuation)
        }
    }

    // MARK: - Sign-in flows

    /// Send a sign-in code to `email`, or run the debug `42` shortcut (dev account from the launch environment).
    public func sendCode(to email: String) async throws {
        try await requireOnline()
        feed("sendCodeStarted")
        var sent = false
        defer { feed(["sendCodeFinished": ["sent": .bool(sent)]]) }

        // The DEBUG dev account comes from the launch environment
        // (`CMUX_UITEST_STACK_EMAIL` / `CMUX_UITEST_STACK_PASSWORD`), never from
        // the source: with neither set, `42` is an ordinary email.
        if launch.includesDevAuth,
           email.trimmingCharacters(in: .whitespacesAndNewlines) == "42",
           let creds = CMUXAuthAutoLoginCredentials(
               environment: launch.environment,
               clearAuth: false,
               mockDataEnabled: false
           ) {
            try await signInWithPassword(email: creds.email, password: creds.password, setLoading: false)
            debugCredentials = creds
            feed("debugCredentialsRemembered")
            return
        }

        do {
            let client = self.client
            let callbackURL = config.magicLinkCallbackURL
            let nonce = try await runPhase(.sendCode, timeout: timeouts.network) {
                try await client.sendMagicLinkEmail(email: email, callbackURL: callbackURL)
            }
            pendingNonce = nonce
            sent = true
        } catch {
            throw AuthError(displaySafe: error) ?? error
        }
    }

    /// Verify a magic-link code against the pending nonce.
    public func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }
        let fullCode = CMUXAuthMagicLinkCode(code: code, nonce: nonce).composed
        let client = self.client
        try await signIn("verifyCode") {
            try await client.signInWithMagicLink(code: fullCode)
        }
    }

    /// Sign in with an email/password credential.
    public func signInWithPassword(email: String, password: String, setLoading: Bool = true) async throws {
        let client = self.client
        try await signIn("password", setsLoading: setLoading) {
            try await client.signInWithCredential(email: email, password: password)
        }
    }

    /// Sign in with Apple.
    public func signInWithApple() async throws { try await signInWithOAuth(provider: "apple") }

    /// Sign in with Google.
    public func signInWithGoogle() async throws { try await signInWithOAuth(provider: "google") }

    /// Sign in with GitHub.
    public func signInWithGitHub() async throws { try await signInWithOAuth(provider: "github") }

    private func signInWithOAuth(provider: String) async throws {
        // Interactive deadline: ASAuthorizationController and
        // ASWebAuthenticationSession callbacks are not guaranteed to fire.
        let client = self.client
        let anchor = self.anchor
        do {
            try await signIn("oauth") {
                try await client.signInWithOAuth(provider: provider, anchor: anchor)
            }
        } catch {
            log.log("auth.oauth provider=\(provider) failed: \(error)")
            throw error
        }
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
        try await signIn("external", exchange: nil)
    }

    /// Runs one sign-in through the reducer: it decides when the exchange,
    /// user fetch and team refresh run, and how the flow ends.
    private func signIn(
        _ kind: String,
        setsLoading: Bool = true,
        exchange: (@Sendable () async throws -> Void)?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            requestedSignIn = PendingSignIn(continuation: continuation, exchange: exchange, kind: kind)
            feed(["signInRequested": ["kind": .string(kind), "setsLoading": .bool(setsLoading)]])
            // The reducer always starts or refuses the flow; this is only a backstop.
            if let unclaimed = requestedSignIn {
                requestedSignIn = nil
                unclaimed.continuation.resume(throwing: AuthError.cancelled)
            }
        }
    }

    /// Sign out, local-first: the device ends signed out immediately, with the
    /// server-side teardown a bounded best-effort tail.
    ///
    /// Local session state (tokens, cached user, team selection, the published
    /// signed-in flags) is cleared before any network I/O, so sign-out behaves
    /// identically with no connectivity. The credentials the server-side
    /// teardown needs are captured with raw stored reads (no network) before
    /// the clear.
    ///
    /// Security tradeoff, chosen deliberately: when the teardown deadline fires
    /// (offline, dead server), the server-side session is NOT revoked, so the
    /// refresh token stays valid server-side until it expires or is revoked
    /// elsewhere. The device's copy is destroyed by the local clear.
    ///
    /// - Parameter onSignedOut: An async hook for token-authenticated teardown
    ///   above this package (e.g. deleting the APNs device token). It receives
    ///   the access/refresh tokens captured before the local clear and runs
    ///   before the Stack session revocation. Defaults to a no-op.
    /// - Parameter teardownTimeout: How long the best-effort server teardown
    ///   (hook + revocation) may run before it is cancelled. Sleeps on the
    ///   injected clock. Defaults to 5 seconds.
    public func signOut(
        onSignedOut: @escaping @Sendable (_ accessToken: String?, _ refreshToken: String?) async -> Void = { _, _ in },
        teardownTimeout: Duration = .seconds(5)
    ) async {
        isCapturingSignOutCredentials = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Each sign-out waits on its own teardown, overlapping or not.
            requestedSignOut = PendingSignOut(onSignedOut: onSignedOut, teardownTimeout: teardownTimeout, continuation: continuation)
            feed("signOutRequested")
            // The reducer queued no capture (it refused the event): nothing
            // will tear down, so do not wait.
            if let unnumbered = requestedSignOut {
                requestedSignOut = nil
                unnumbered.continuation.resume()
            }
        }
        finishSignOutCredentialCapture()
    }

    // MARK: - State helpers

    /// Signs the app out locally: the one place every sign-out goes through,
    /// so each one leaves a record of why (`reason`, logged at error level
    /// and kept in ``lastSignOutReason``).
    func clearAuthState(reason: String, preservePendingCode: Bool = false) {
        feed(["clearAuthStateRequested": ["reason": .string(reason), "preservePendingCode": .bool(preservePendingCode)]])
    }

    var sessionGeneration: UInt64 { snapshot.sessionGeneration }
    var signOutEpoch: UInt64 { snapshot.signOutRevision }
    var tokenStoreWriteHighWater: UInt64 { snapshot.tokenStoreWriteHighWater }
    var hasActiveSignInFlows: Bool { snapshot.hasActiveSignInFlows }
    /// Why the app last signed out locally (``clearAuthState(reason:preservePendingCode:)``).
    var lastSignOutReason: String? { snapshot.lastSignOutReason }

    /// Whether one coordinator-owned transition (launch restore, a sign-in, or
    /// sign-out's credential capture) can legitimately observe an empty token
    /// store before it reaches its terminal state. Token readers then return a
    /// retryable error instead of clearing state out from under the writer.
    var sessionTokenTransitionIsActive: Bool {
        snapshot.sessionTokenTransitionIsActive || isCapturingSignOutCredentials
    }

    func requireOnline() async throws {
        guard await isOnline() else {
            throw AuthError.offline
        }
    }

    func loadCachedUser() -> CMUXAuthUser? { Self.loadCachedUser(userCache) }

    static func loadCachedUser(_ userCache: CMUXAuthIdentityStore) -> CMUXAuthUser? {
        do {
            return try userCache.load()
        } catch {
            authLog.error("Failed to load cached user: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func saveCachedUser(_ user: CMUXAuthUser) {
        do {
            try userCache.save(user)
        } catch {
            authLog.error("Failed to cache user: \(error.localizedDescription, privacy: .private)")
        }
    }

    var autoLoginCredentials: CMUXAuthAutoLoginCredentials? {
        CMUXAuthAutoLoginCredentials(
            environment: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
    }
}

/// A sign-in caller waiting for the reducer to end its flow.
struct PendingSignIn {
    let continuation: CheckedContinuation<Void, any Error>
    let exchange: (@Sendable () async throws -> Void)?
    let kind: String
}

/// A sign-out caller and the teardown it asked for.
struct PendingSignOut {
    let onSignedOut: @Sendable (_ accessToken: String?, _ refreshToken: String?) async -> Void
    let teardownTimeout: Duration
    let continuation: CheckedContinuation<Void, Never>
    var postSignInHooks: [UInt64] = []
    var capturedTokens: (accessToken: String?, refreshToken: String?) = (nil, nil)
}
