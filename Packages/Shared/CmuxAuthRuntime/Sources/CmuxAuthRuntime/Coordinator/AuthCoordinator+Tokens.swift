internal import CMUXAuthCore
import Foundation
import OSLog

private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

extension AuthCoordinator {
    // MARK: - Tokens

    /// The current access token.
    ///
    /// Classifies a missing token the same way ``forceRefreshAccessToken()``
    /// does, so the connection layer can tell a recoverable session from a dead
    /// one: when the SDK could not hand back an access token but a refresh token
    /// is still stored, or token storage was unavailable because the device was
    /// locked, the failure was transient and this throws
    /// ``AuthError/networkError`` so the caller retries without signing out.
    /// When neither token survives from available storage, the session is
    /// genuinely gone, so this calls ``clearAuthState()`` (flipping
    /// ``isAuthenticated`` to `false`, which routes the root scene to the
    /// sign-in page) and throws
    /// ``AuthError/unauthorized``.
    /// - Returns: A current access token.
    /// - Throws: ``AuthError/networkError`` on a transient failure with a
    ///   surviving refresh token or unavailable token storage (retryable);
    ///   ``AuthError/unauthorized`` once the session is definitively gone (also
    ///   clears local auth state).
    public func accessToken() async throws -> String {
        do {
            return try await runTokenTouchingPhase(.accessToken, timeout: timeouts.network) {
                try await self.accessTokenWithoutStateClear()
            }
        } catch AuthError.unauthorized {
            // A session transition owns the temporarily empty token store. This
            // method is a reader, so it cannot publish a signed-out verdict or
            // bump sessionGeneration out from under that writer. Callers retry
            // after restore/sign-in reaches its terminal state.
            if sessionTokenTransitionIsActive {
                throw AuthError.networkError
            }
            if let devToken = await devAuthAccessTokenFallback() {
                return devToken
            }
            clearAuthState(preservePendingCode: true)
            throw AuthError.unauthorized
        }
    }

    /// Returns the currently stored access token without refreshing or mutating auth state.
    public func storedAccessToken() async -> String? {
        await client.storedAccessToken()
    }

    private func accessTokenWithoutStateClear() async throws -> String {
        let storageWasAvailable = await isTokenStorageAvailable()
        if let token = await client.accessToken() {
            return token
        }
        #if DEBUG
        if launch.mockDataEnabled {
            return "cmux-ui-test-stack-token"
        }
        #endif
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session and the user must sign in again.
        // The caller performs the published-state clear only for the winning,
        // current request; late timed-out token tasks must not mutate auth UI.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
    }

    private func devAuthAccessTokenFallback() async -> String? {
        #if DEBUG
        guard launch.includesDevAuth, let credentials = debugCredentials else {
            return nil
        }
        try? await signInWithPassword(
            email: credentials.email,
            password: credentials.password,
            setLoading: false
        )
        return await client.accessToken()
        #else
        return nil
        #endif
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
    /// - Throws: ``AuthError/networkError`` when the access token is missing
    ///   but a refresh token survives, meaning the refresh failed transiently,
    ///   or when token storage was unavailable because the device was locked;
    ///   ``AuthError/unauthorized`` when available storage is missing either an
    ///   access token with no refresh token to recover from, or the refresh
    ///   token required by backend requests.
    public func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        await awaitBootstrapped()
        let storageWasAvailable = await isTokenStorageAvailable()
        guard let access = await client.accessToken(), !access.isEmpty else {
            if let refresh = await client.refreshToken(), !refresh.isEmpty {
                throw AuthError.networkError
            }
            throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
        }
        guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
            throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
        }
        return (access, refresh)
    }

    /// Both tokens for the current session as ONE coherent pair, for callers that
    /// must never send a torn (old-access, new-refresh) credential set.
    ///
    /// ``currentTokens()`` reads the access and refresh tokens through two
    /// separate awaits, so a ``forceRefreshAccessToken()`` landing between them
    /// can rotate the pair and return an old access token with a rotated refresh
    /// token. This instead brackets the read with the refresh token: capture the
    /// refresh, resolve the access token through the LIVE store — a still-fresh
    /// stored token comes back without the network (an offline caller with a
    /// valid stored pair succeeds), and a stale one is refreshed through the
    /// SDK's own store, persisted and deduplicated with concurrent refreshes so
    /// repeated captures never re-mint — then re-read the refresh token. An
    /// unchanged refresh proves no rotation crossed the window, so the resolved
    /// access belongs to the returned refresh; a changed one retries against
    /// the new capture. The read runs inside the coordinator's bounded
    /// token-touching phase like every other token accessor.
    /// - Returns: The access and refresh tokens from one coherent capture.
    /// - Throws: ``AuthError/networkError`` when the refresh token survives but a
    ///   usable access token cannot be resolved for it (transient), when token
    ///   storage was unavailable, or when rotation kept crossing the read window;
    ///   ``AuthError/unauthorized`` when available storage has no refresh token
    ///   to resolve an access token for.
    public func coherentTokenPair() async throws -> (accessToken: String, refreshToken: String) {
        try await runTokenTouchingPhase(.accessToken, timeout: timeouts.network) {
            try await self.coherentTokenPairWithoutStateClear()
        }
    }

    private func coherentTokenPairWithoutStateClear() async throws -> (accessToken: String, refreshToken: String) {
        let storageWasAvailable = await isTokenStorageAvailable()
        for _ in 0..<3 {
            guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
                throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
            }
            // Resolve the access token through the LIVE store: a still-fresh
            // stored token is returned without the network, and a stale one is
            // refreshed through the SDK's own store — persisted, and
            // deduplicated with any concurrent refresh — so repeated captures
            // never re-mint a token the store already refreshed.
            guard let access = await client.accessToken(), !access.isEmpty else {
                // The refresh token survived but no usable access token could
                // be resolved: stay retryable, matching currentTokens()'s
                // classification of a surviving-refresh access miss.
                throw AuthError.networkError
            }
            // The bracket: an unchanged refresh across the access resolution
            // proves no rotation crossed the window, so the pair is coherent.
            if await client.refreshToken() == refresh {
                return (access, refresh)
            }
        }
        // Rotation kept crossing the window; the session is alive, so report
        // retryable rather than signed-out.
        throw AuthError.networkError
    }

    /// The current session generation. Bumped on every session transition (each
    /// sign-out and each sign-in), so a caller can pin a multi-step operation to
    /// one session and reject it the moment the generation moves.
    public var authSessionGeneration: UInt64 { sessionGeneration }

    /// Captures the signed-in account id and both tokens as one consistent
    /// snapshot, so the identity and the credentials provably belong to the same
    /// session.
    ///
    /// The account id is read from ``currentUser`` before and after the token
    /// read and the session generation is required to be unchanged across it, so
    /// a session transition (sign-out then sign-in as a different user) landing
    /// during the read is rejected instead of returning account A's id paired
    /// with account B's freshly-stored tokens. This closes the gap where a
    /// lagging observed identity authorizes an action that then runs with a
    /// different account's credentials.
    ///
    /// Both guards also require that no coordinator-owned token transition is in
    /// flight (``sessionTokenTransitionIsActive``). The generation is bumped at
    /// only one instant in a transition, so a snapshot taken elsewhere in the
    /// transition window could still read a half-updated identity/token pair that
    /// happens to match the pinned generation; rejecting whenever a transition
    /// owns the store closes that window at both ends of the token read.
    ///
    /// A complete persisted pair is served straight from the keychain without
    /// awaiting launch restore or foreground revalidation (see
    /// ``storedSessionSnapshot()``): those are network round trips, and a
    /// connection attempt must not queue behind them when the tokens it needs
    /// are already stored locally.
    ///
    /// - Returns: The pinned generation, account id, and both tokens.
    /// - Throws: ``AuthError/networkError`` when no usable stored pair exists
    ///   while a session transition (launch or foreground revalidation,
    ///   sign-in restore) owns the token store — the same signed-in session
    ///   serves the pair the moment the transition completes, so the caller
    ///   retries instead of treating the window as signed out;
    ///   ``AuthError/unauthorized`` when no account is signed in or the
    ///   session changed mid-read; otherwise the same token errors as
    ///   ``coherentTokenPair()``.
    public func authenticatedSessionSnapshot() async throws -> AuthenticatedSessionSnapshot {
        // Serve the persisted pair straight from the keychain when one exists:
        // launch restore and foreground revalidation are network round trips,
        // and a connection attempt must not queue behind them when the tokens
        // it needs are already stored locally. Backend calls send BOTH tokens,
        // so a stale-but-refreshable access token still authenticates
        // server-side; a store with no usable pair falls through to the full
        // bootstrap-awaiting path below.
        if let stored = await storedSessionSnapshot() {
            return stored
        }
        await awaitBootstrapped()
        guard isAuthenticated,
              let accountID = currentUser?.id,
              !accountID.isEmpty else {
            throw AuthError.unauthorized
        }
        // A transition-owned token store is transient: every foreground return
        // revalidates the session over the network, and classifying that
        // window as unauthorized made the iroh broker source fail closed on
        // every app launch. Match `accessToken()`'s classification.
        guard !sessionTokenTransitionIsActive else {
            throw AuthError.networkError
        }
        let generation = sessionGeneration
        // Read both tokens as one coherent pair so a concurrent force refresh
        // cannot pair an old access token with a rotated refresh token; the
        // separately-read `currentTokens()` cannot make that guarantee.
        let tokens = try await coherentTokenPair()
        guard sessionGeneration == generation,
              currentUser?.id == accountID else {
            throw AuthError.unauthorized
        }
        guard !sessionTokenTransitionIsActive else {
            throw AuthError.networkError
        }
        return AuthenticatedSessionSnapshot(
            generation: generation,
            accountID: accountID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }

    /// The persisted session pair as an immediate snapshot, or `nil` when the
    /// stored pair cannot be trusted and the caller must take the full path.
    ///
    /// Reads are keychain-only (``AuthClient/storedAccessToken()`` never
    /// refreshes over the network), so this returns in microseconds regardless
    /// of what launch restore or foreground revalidation is doing. Declines
    /// (returns `nil`, never throws) when:
    /// - the launch requested an auth-environment switch
    ///   (`clearStaleAuthOnLaunch`): the persisted tokens belong to the other
    ///   Stack project until the bootstrap clear runs, so they must never be
    ///   served;
    /// - a sign-in exchange or sign-out credential capture owns the store: a
    ///   mid-exchange read could pair the OLD published identity with the NEW
    ///   session's freshly-written tokens (revalidation, by contrast, is
    ///   read-only over the surviving session and is exactly the window this
    ///   fast path exists to serve);
    /// - no primed identity or no complete stored pair exists;
    /// - the refresh token changed across the reads (a rotation crossed the
    ///   window) or the session generation/identity moved.
    private func storedSessionSnapshot() async -> AuthenticatedSessionSnapshot? {
        guard !launch.shouldClearStoredSessionBeforePriming else { return nil }
        guard activeSignInFlows.isEmpty, !isCapturingSignOutCredentials else { return nil }
        guard isAuthenticated,
              let accountID = currentUser?.id,
              !accountID.isEmpty else { return nil }
        let generation = sessionGeneration
        guard let refresh = await client.refreshToken(), !refresh.isEmpty else { return nil }
        guard let access = await client.storedAccessToken(), !access.isEmpty else { return nil }
        // The bracket: an unchanged refresh token across the access read
        // proves no rotation crossed the window, so the pair is coherent.
        guard await client.refreshToken() == refresh else { return nil }
        // Re-check every guard that could have moved across the awaits: a
        // sign-out, sign-in, or account switch landing mid-read must win.
        guard sessionGeneration == generation,
              currentUser?.id == accountID,
              activeSignInFlows.isEmpty,
              !isCapturingSignOutCredentials else { return nil }
        return AuthenticatedSessionSnapshot(
            generation: generation,
            accountID: accountID,
            accessToken: access,
            refreshToken: refresh
        )
    }

    /// Captures the signed-in account id and refresh token under one session
    /// generation without requiring an access token.
    ///
    /// Browser handoff authenticates directly with Stack's refresh token. A
    /// refresh-token-only launch is therefore valid, but the identity, token,
    /// and generation must still be read as one consistent session so an
    /// account switch cannot finish an exchange for the previous account.
    public func authenticatedRefreshTokenSnapshot() async throws
        -> AuthenticatedRefreshTokenSnapshot
    {
        await awaitBootstrapped()
        guard isAuthenticated,
              !sessionTokenTransitionIsActive,
              let accountID = currentUser?.id,
              !accountID.isEmpty else {
            throw AuthError.unauthorized
        }
        let generation = sessionGeneration
        let storageWasAvailable = await isTokenStorageAvailable()
        guard let refreshToken = await client.refreshToken(),
              !refreshToken.isEmpty else {
            throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
        }
        guard sessionGeneration == generation,
              !sessionTokenTransitionIsActive,
              currentUser?.id == accountID else {
            throw AuthError.unauthorized
        }
        return AuthenticatedRefreshTokenSnapshot(
            generation: generation,
            accountID: accountID,
            refreshToken: refreshToken
        )
    }

    /// Force-mint a fresh access token, bypassing the cached-token freshness
    /// check. Call this after the host rejected the current token so the retry
    /// presents a genuinely new credential instead of the same rejected one.
    ///
    /// - Returns: A freshly minted access token.
    /// - Throws: ``AuthError/networkError`` when the refresh failed transiently
    ///   but the session is intact (a refresh token is still stored), or when
    ///   token storage was unavailable because the device was locked, so the
    ///   caller should retry rather than sign out; ``AuthError/unauthorized``
    ///   only when the session is genuinely gone from available storage (the
    ///   refresh token was definitively rejected and cleared). The definitive
    ///   case also calls ``clearAuthState()`` so ``isAuthenticated`` flips to
    ///   `false` and the root scene routes to the sign-in page instead of
    ///   showing a stale shell.
    public func forceRefreshAccessToken() async throws -> String {
        do {
            return try await runTokenTouchingPhase(.forceRefreshAccessToken, timeout: timeouts.network) {
                try await self.forceRefreshAccessTokenWithoutStateClear()
            }
        } catch AuthError.unauthorized {
            if sessionTokenTransitionIsActive {
                throw AuthError.networkError
            }
            clearAuthState(preservePendingCode: true)
            throw AuthError.unauthorized
        }
    }

    private func forceRefreshAccessTokenWithoutStateClear() async throws -> String {
        let storageWasAvailable = await isTokenStorageAvailable()
        if let token = await client.forceRefreshAccessToken() {
            return token
        }
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        throw emptyTokenReadError(storageWasAvailable: storageWasAvailable)
    }

    private func emptyTokenReadError(storageWasAvailable: Bool) -> AuthError {
        storageWasAvailable ? .unauthorized : .networkError
    }
}

/// Immutable snapshot of the authenticated session: the account id and both
/// tokens captured together with the session generation they belong to.
///
/// The generation lets a long operation (revoking bindings, say) detect that the
/// session was replaced after the snapshot, so it aborts before acting with one
/// account's identity and another's credentials.
public struct AuthenticatedSessionSnapshot: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// The session generation the account id and tokens were captured under.
    public let generation: UInt64
    /// The signed-in account id (`currentUser.id`) at capture.
    public let accountID: String
    /// The access token for this session.
    public let accessToken: String
    /// The refresh token for this session.
    public let refreshToken: String

    public init(
        generation: UInt64,
        accountID: String,
        accessToken: String,
        refreshToken: String
    ) {
        self.generation = generation
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Redacted: the synthesized reflection would copy live tokens (and the
    /// account id) into logs, assertion output, and crash reports.
    public var description: String {
        "AuthenticatedSessionSnapshot(generation: \(generation), "
            + "accountID: <redacted>, accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Credential-free identity for synchronously binding queued work to the
/// current authenticated session.
public struct AuthenticatedSessionIdentity: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UInt64
    public let accountID: String

    public init(generation: UInt64, accountID: String) {
        self.generation = generation
        self.accountID = accountID
    }

    public var description: String {
        "AuthenticatedSessionIdentity(generation: \(generation), accountID: <redacted>)"
    }

    public var debugDescription: String { description }
}

public extension AuthCoordinator {
    /// The current account plus session generation without either credential.
    var authenticatedSessionIdentity: AuthenticatedSessionIdentity? {
        guard isAuthenticated,
              !sessionTokenTransitionIsActive,
              let accountID = currentUser?.id,
              !accountID.isEmpty else { return nil }
        return AuthenticatedSessionIdentity(
            generation: authSessionGeneration,
            accountID: accountID
        )
    }

    /// A credential-free lifecycle stream for consumers that must cancel work
    /// at the exact auth transition instead of discovering stale authority on
    /// their next request. The first element is always the current state.
    func authenticatedSessionIdentities()
        -> AsyncStream<AuthenticatedSessionIdentity?> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            authenticatedSessionIdentityContinuations[continuationID] =
                continuation
            continuation.yield(publishedAuthenticatedSessionIdentity)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.authenticatedSessionIdentityContinuations[
                        continuationID
                    ] = nil
                }
            }
        }
    }

    /// Whether a credential-free identity still names the published session.
    /// This stays stable through same-account revalidation but flips false at
    /// the synchronous start of sign-out.
    func isAuthenticatedSessionIdentityCurrent(
        _ identity: AuthenticatedSessionIdentity
    ) -> Bool {
        publishedAuthenticatedSessionIdentity == identity
    }
}

extension AuthCoordinator {
    private var publishedAuthenticatedSessionIdentity:
        AuthenticatedSessionIdentity? {
        guard isAuthenticated,
              !isCapturingSignOutCredentials,
              let accountID = currentUser?.id,
              !accountID.isEmpty else { return nil }
        return AuthenticatedSessionIdentity(
            generation: authSessionGeneration,
            accountID: accountID
        )
    }

    func publishAuthenticatedSessionIdentity() {
        let identity = publishedAuthenticatedSessionIdentity
        for continuation in authenticatedSessionIdentityContinuations.values {
            continuation.yield(identity)
        }
    }
}
