internal import CMUXAuthCore
import Foundation
import OSLog

nonisolated private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

extension AuthCoordinator {
    // MARK: - Priming

    /// The one-shot launch bootstrap ``AuthCoordinator/start()`` runs: on an
    /// auth-environment switch, drop the other Stack project's persisted
    /// tokens BEFORE the restore probe — stale foreign-project tokens must
    /// neither restore nor make `shouldStartAutoLogin` skip the DEBUG
    /// auto-login — then run the normal existing-session check.
    func bootstrapSession() async {
        if launch.clearStaleAuthOnLaunch {
            await clearPersistedStackSession()
        }
        await checkExistingSession()
    }

    func primeSessionState() {
        if launch.clearAuthRequested {
            clearAuthState()
            Task { await clearPersistedAuthForUITest() }
            return
        }

        // Auth-environment switch: drop the other Stack project's local
        // caches synchronously so no stale identity primes or flashes — but
        // unlike the UI-test clear above, do NOT return: normal priming
        // continues, so DEBUG auto-login credentials keep working on this
        // same launch. ``AuthCoordinator/start()`` clears the persisted
        // tokens (awaited) before the restore probe.
        if launch.clearStaleAuthOnLaunch {
            clearAuthState()
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

    func checkExistingSession() async {
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
        // while these reads are parked, so bound the probe and re-check the
        // generation after. A timeout preserves the cached identity instead of
        // leaving launch behind "Restoring session".
        let hasStoredTokens: Bool
        do {
            let client = self.client
            hasStoredTokens = try await runPhase(.validateSession, timeout: timeouts.sessionRestore) {
                let hasAccessToken = await client.accessToken() != nil
                let hasRefreshToken = await client.refreshToken() != nil
                return hasAccessToken || hasRefreshToken
            }
        } catch {
            guard generation == sessionGeneration else { return }
            authLog.error("Session token probe failed: \(error.localizedDescription, privacy: .private)")
            preserveCachedSessionAfterValidationFailure()
            return
        }
        guard generation == sessionGeneration else { return }

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

        clearAuthState(preservePendingCode: true)
    }

    /// Run the launch/dev auto-login, capturing the same staleness context as
    /// the validation flows (`generation` / `storeWriteHighWater` from the
    /// caller's entry) so its failure cleanup cannot wipe a session
    /// established after the auto-login began.
    func performAutoLogin(
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
            // No expected refresh token: auto-login only starts against an
            // empty token store, so there is no dead session's token to
            // compare against; the staleness guards inside cover the rest.
            await clearStaleSessionState(
                generation: generation,
                storeWriteHighWater: storeWriteHighWater,
                expectedRefreshToken: nil
            )
        }
    }

    func validateCachedSession(generation: UInt64, storeWriteHighWater: UInt64) async {
        do {
            let client = self.client
            let user = try await runPhase(.validateSession, timeout: timeouts.sessionRestore) {
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
            // Snapshot the dead session's refresh token right before the
            // clear so the clear can be compare-and-clear at the token store.
            let expectedRefreshToken = try await runPhase(.validateSession, timeout: timeouts.sessionRestore) {
                await client.refreshToken()
            }
            guard generation == sessionGeneration else { return }
            await clearStaleSessionState(
                generation: generation,
                storeWriteHighWater: storeWriteHighWater,
                expectedRefreshToken: expectedRefreshToken
            )
        } catch {
            // Same staleness rule for the failure paths: a stale clear here
            // could wipe a session established after this flow began.
            guard generation == sessionGeneration else { return }
            if error is CancellationError || (error as? AuthError) == .cancelled {
                authLog.info("Cached session validation superseded by a newer session transition; leaving state untouched")
                return
            }
            recordAuthError(error)
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
            if (error as? AuthError) == .timedOut {
                authLog.error("Session validation timed out; preserving cached session")
                preserveCachedSessionAfterValidationFailure()
                return
            }
            let survivingRefreshToken: String?
            do {
                let client = self.client
                survivingRefreshToken = try await runPhase(.validateSession, timeout: timeouts.sessionRestore) {
                    await client.refreshToken()
                }
            } catch {
                authLog.error("Session refresh-token check failed: \(error.localizedDescription, privacy: .private)")
                preserveCachedSessionAfterValidationFailure()
                return
            }
            guard generation == sessionGeneration else { return }
            if survivingRefreshToken == nil {
                authLog.error(
                    "Session validation failed and no refresh token survives; routing to login error=\(error.localizedDescription, privacy: .private)"
                )
                await clearStaleSessionState(
                    generation: generation,
                    storeWriteHighWater: storeWriteHighWater,
                    expectedRefreshToken: nil
                )
                return
            }
            let action = AuthError(displaySafe: error)?.cachedSessionValidationFailureAction
                ?? .preserveCachedSession
            authLog.error(
                "Session validation failed action=\(action.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            switch action {
            case .clearSession:
                await clearStaleSessionState(
                    generation: generation,
                    storeWriteHighWater: storeWriteHighWater,
                    expectedRefreshToken: survivingRefreshToken
                )
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
    /// is not unpublished by the stale failure.
    ///
    /// The store clear itself is a compare-and-clear against
    /// `expectedRefreshToken` (the dead session's refresh token, snapshotted
    /// by the caller right before this call), atomic at the token store: the
    /// high-water check above can only see writes that have already advanced
    /// the mark, so a fresh sign-in writing while this clear is suspended
    /// in flight would otherwise be wiped underneath its own publish. With
    /// the compare, a store that changed owners after the cleanup decision
    /// is left alone. `nil` means the dead session had no refresh token to
    /// compare against; the clear falls back to unconditional, where the
    /// only exposure is a refresh-less store racing a sign-in's write
    /// (anomalous: the SDK always persists a refresh token with a session).
    func clearStaleSessionState(
        generation: UInt64,
        storeWriteHighWater: UInt64,
        expectedRefreshToken: String?
    ) async {
        guard tokenStoreWriteHighWater == storeWriteHighWater else { return }
        if let expectedRefreshToken {
            await client.clearLocalSession(ifRefreshTokenMatches: expectedRefreshToken)
        } else {
            await clearPersistedStackSession()
        }
        guard generation == sessionGeneration,
              tokenStoreWriteHighWater == storeWriteHighWater else { return }
        clearAuthState(preservePendingCode: true)
    }
}
