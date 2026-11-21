internal import CMUXAuthCore
import Foundation
import OSLog
import StackAuth

private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

/// The runner: feeds the reducer, runs the effects it queues, and copies what
/// it publishes into the observable properties. Every decision lives in the
/// reducer; an effect here does the I/O it names and feeds the answer back.
@MainActor
extension AuthCoordinator {
    func feed(_ event: AuthWire) {
        do {
            try engine.feed(JSONEncoder().encode(event))
        } catch {
            authLog.error("auth: the reducer refused \(event.variant.tag, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        refreshSnapshot()
        drain()
    }

    /// Runs queued effects until the reducer has none left. Effects that feed
    /// synchronously queue more; the loop picks them up.
    func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while true {
            let effects = (try? JSONDecoder().decode([AuthWire].self, from: engine.takeEffects())) ?? []
            if effects.isEmpty { break }
            for effect in effects { run(effect) }
            mirror()
        }
        mirror()
    }

    private func refreshSnapshot() {
        do {
            snapshot = try JSONDecoder().decode(AuthReducerSnapshot.self, from: engine.snapshot())
        } catch {
            authLog.error("auth: the reducer's snapshot did not decode, keeping the last: \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the snapshot into the stored observable properties, writing only
    /// what changed so observers see no spurious updates.
    private func mirror() {
        isMirroring = true
        defer { isMirroring = false }
        let s = snapshot
        if isAuthenticated != s.isAuthenticated { isAuthenticated = s.isAuthenticated }
        let user = s.currentUser?.user
        if currentUser != user { currentUser = user }
        if isRestoringSession != s.isRestoringSession { isRestoringSession = s.isRestoringSession }
        if isLoading != s.isLoading { isLoading = s.isLoading }
        if availableTeams != s.availableTeams { availableTeams = s.availableTeams }
        if selectedTeamID != s.selectedTeamId { selectedTeamID = s.selectedTeamId }
    }

    static func reducerConfig(
        launch: AuthLaunchOptions,
        cachedUser: CMUXAuthUser?,
        hasTokens: Bool,
        selectedTeamID: String?
    ) -> AuthWire {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        let fixtureUser = CMUXAuthUser(
            uiTestFixtureEnvironment: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
        let autoLogin = CMUXAuthAutoLoginCredentials(
            environment: launch.environment,
            clearAuth: launch.clearAuthRequested,
            mockDataEnabled: launch.mockDataEnabled
        )
        return [
            "launch": [
                "clearAuthRequested": .bool(launch.clearAuthRequested),
                "mockDataEnabled": .bool(launch.mockDataEnabled),
                "includesDevAuth": .bool(launch.includesDevAuth),
                "clearStaleAuthOnLaunch": .bool(launch.clearStaleAuthOnLaunch),
                "replaceStoredSessionWithAutoLogin": .bool(launch.replaceStoredSessionWithAutoLogin),
                "environmentAutoLogin": .bool(launch.environmentAutoLogin),
                "debugBuild": .bool(debugBuild),
                "fixtureUser": fixtureUser.map { AuthWire(encoding: AuthWireUser($0)) } ?? .null,
                "fixtureTeamsRequested": .bool(launch.environment["CMUX_UITEST_AUTH_FIXTURE_TEAMS"] != nil),
                "autoLogin": autoLogin.map { ["emailIsEmpty": .bool($0.email.isEmpty)] } ?? .null,
            ],
            "persisted": [
                "cachedUser": cachedUser.map { AuthWire(encoding: AuthWireUser($0)) } ?? .null,
                "hasTokens": .bool(hasTokens),
                "selectedTeamId": AuthWire(selectedTeamID),
            ],
            "jitterSeed": .int(Int64.random(in: 0..<(1 << 53))),
        ]
    }

    // MARK: - Effects

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ effect: AuthWire) {
        let (tag, payload) = effect.variant
        switch tag {
        // State and persistence.
        case "notifySessionWillTransition": onSessionWillTransition()
        case "publishSessionIdentity":
            let identity = payload.decoded(AuthReducerSnapshot.Identity.self)?.identity
            for continuation in authenticatedSessionIdentityContinuations.values { continuation.yield(identity) }
        case "publishTeamScope":
            let scope = payload.decoded(AuthReducerSnapshot.Scope.self)?.scope
            for continuation in authenticatedTeamScopeContinuations.values { continuation.yield(scope) }
        case "saveCachedUser":
            if let user = payload.decoded(AuthWireUser.self) { saveCachedUser(user.user) }
        case "clearCachedUser": userCache.clear()
        case "setHasTokens": sessionCache.setHasTokens(true)
        case "clearSessionCache": sessionCache.clear()
        case "persistSelectedTeam": teamSelection.selectedTeamID = payload.string
        case "dropPendingCode": pendingNonce = nil
        case "recordLatestSignInRefreshToken":
            if exchangeRecordedRefreshToken {
                exchangeRecordedRefreshToken = false
            } else {
                let client = self.client
                Task { latestSignInRefreshToken = await client.refreshToken() }
            }
        case "forgetLatestSignInRefreshToken": latestSignInRefreshToken = nil
        case "forgetDebugCredentials": debugCredentials = nil
        case "logSignOut":
            authLog.error("Signing out locally reason=\(payload["reason"].string ?? "", privacy: .public)")
        case "clearLocalSession": clearLocalSession()
        case "clearStaleSession": clearStaleSession(payload)

        // Restore.
        case "probeStoredTokens": probeStoredTokens(payload)
        case "validateCachedSession": validateCachedSession(payload)
        case "readSurvivingRefreshToken": readSurvivingRefreshToken(payload)
        case "checkTokenStorageAvailable":
            let available = isTokenStorageAvailable
            Task {
                let isAvailable = await available()
                feed(["tokenStorageAvailability": ["ticket": payload, "available": .bool(isAvailable)]])
            }
        case "retryProbeAfter":
            let clock = self.clock
            Task {
                let cancelled = (try? await clock.sleep(for: payload["delay"].duration, tolerance: nil)) == nil
                feed(["probeRetryDue": ["ticket": payload["ticket"], "cancelled": .bool(cancelled)]])
            }
        case "autoLogin": autoLogin(payload)
        case "joinRestore": break
        case "restoreFinished": finishRestore()

        // Sign-in.
        case "setLoading": isLoading = payload.bool
        case "clearExternalSignInFailureDetail": lastExternalSignInFailureDetail = nil
        case "quiesceTokenWork": quiesceTokenWork(payload)
        case "checkOnline":
            let isOnline = self.isOnline
            Task {
                let online = await isOnline()
                feed(["onlineChecked": ["flow": payload, "online": .bool(online)]])
            }
        case "runExchange": runSignInExchange(payload)
        case "fetchUser": fetchSignInUser(payload)
        case "signInSucceeded":
            signInErrors[payload["attempt"].uint] = nil
            signIns.removeValue(forKey: payload["attempt"].uint)?.continuation.resume()
        case "signInFailed": failSignIn(flow: payload["flow"], failure: payload["failure"])

        // Teams.
        case "refreshTeams": refreshTeams(ticket: payload)
        case "runPostSignInHook":
            let onSignedIn = self.onSignedIn
            Task {
                await runPostSignInHook(timeout: timeouts.network) { await onSignedIn() }
                feed(["postSignInHookFinished": ["ticket": payload]])
            }
        case "sessionCheckRateLimited":
            guard let limit = lastRateLimit else { break }
            rateLimitTelemetry.rateLimited(
                .sessionCheck,
                rateLimit: limit,
                backoff: payload["backoff"].duration,
                attempt: Int(payload["attempt"].uint)
            )
        case "sessionCheckSucceeded": rateLimitTelemetry.succeeded(.sessionCheck)
        case "sleepTeamScopeRecovery": sleepTeamScopeRecovery(id: payload["id"].uint, delay: payload["delay"].duration)
        case "cancelTeamScopeRecovery":
            teamScopeRecoveryTasks.removeValue(forKey: payload["id"].uint)?.cancel()

        // Sign-out and token reads.
        case "cancelInFlightWork":
            // Cancel in-flight exchanges first: the SDK's token-write chokepoint
            // refuses to store after cancellation, so a parked exchange cannot
            // re-store credentials behind this sign-out's local clear.
            for exchange in activeSignInExchanges.values { exchange.task.cancel() }
            for validation in activeSessionValidations.values { validation.cancel() }
            cancelPostSignInHooksForSignOut()
            for phase in activeTokenTouchingPhases.values { phase.cancel() }
        case "clearPhaseDampers":
            let phases = payload.array.compactMap { $0.string.flatMap(AuthPhase.init(rawValue:)) }
            let registry = phaseTimeoutRegistry
            phaseDampersCleared = Task { await registry.clear(phases) }
        case "captureTeardownCredentialsAndClearLocalSession": captureTeardownCredentials(payload)
        case "endSignOutCredentialCapture": finishSignOutCredentialCapture()
        case "waitForPostSignInHooks": pendingSignOut?.waitsForPostSignInHooks = true
        case "serverTeardown": serverTeardown()
        case "failTokenRead": tokenReadFailure = Self.authError(payload)
        case "tryDevAuthAccessToken": tokenReadTriesDevAuth = true
        default:
            assertionFailure("Unknown auth effect \(tag)")
        }
    }

    // MARK: - Local session

    private func clearLocalSession() {
        let client = self.client
        let previous = lastLocalClear
        lastLocalClear = Task {
            await previous?.value
            await client.clearLocalSession()
        }
    }

    private func clearStaleSession(_ payload: AuthWire) {
        let ticket = payload["ticket"]
        let reason = payload["reason"].string ?? "unspecified"
        let expected = payload["compareRefreshToken"].bool ? survivingRefreshTokens[ticket["id"].uint] : nil
        authLog.error(
            "Clearing stale session state reason=\(reason, privacy: .public) compareAndClear=\(expected != nil, privacy: .public)"
        )
        let client = self.client
        Task {
            if let expected {
                await client.clearLocalSession(ifRefreshTokenMatches: expected)
            } else {
                await client.clearLocalSession()
            }
            feed(["staleSessionCleared": ["ticket": ticket, "reason": .string(reason)]])
        }
    }

    // MARK: - Restore

    private func probeStoredTokens(_ ticket: AuthWire) {
        restoreInFlight = true
        let client = self.client
        let restoreTimeout = timeouts.sessionRestore
        let clear = lastLocalClear
        Task {
            await clear?.value
            await StackAuthRateLimitReporting.$callerReports.withValue(true) {
                let baseline = await tokenReadBaseline()
                restoreReadBaselines[ticket["id"].uint] = baseline
                let probe: AuthWire
                do {
                    let hasTokens = try await runPhase(.validateSession, timeout: restoreTimeout) {
                        let hasAccessToken = await client.accessToken() != nil
                        let hasRefreshToken = await client.refreshToken() != nil
                        return hasAccessToken || hasRefreshToken
                    }
                    probe = .ok(.bool(hasTokens))
                } catch {
                    authLog.error("Session token probe failed: \(error.localizedDescription, privacy: .private)")
                    probe = .err(wireFailure(error))
                }
                let readFailed = await tokenReadFailed(since: baseline)
                feed(["tokensProbed": [
                    "ticket": ticket, "probe": probe,
                    "storageWasAvailable": .bool(baseline.storageWasAvailable), "readFailed": .bool(readFailed),
                ]])
            }
        }
    }

    private func validateCachedSession(_ ticket: AuthWire) {
        let client = self.client
        let restoreTimeout = timeouts.sessionRestore
        Task {
            await StackAuthRateLimitReporting.$callerReports.withValue(true) {
                restoreReadBaselines[ticket["id"].uint] = await tokenReadBaseline()
                let result: AuthWire
                do {
                    let user = try await runPhase(.validateSession, timeout: restoreTimeout) {
                        try await client.currentUser(throwOnMissing: true)
                    }
                    result = .ok(user.map { AuthWire(encoding: AuthWireUser($0)) } ?? .null)
                } catch {
                    authLog.error("Session validation failed: \(error.localizedDescription, privacy: .private)")
                    result = .err(wireFailure(error))
                }
                feed(["cachedSessionValidated": ["ticket": ticket, "result": result]])
            }
        }
    }

    private func readSurvivingRefreshToken(_ payload: AuthWire) {
        let ticket = payload["ticket"]
        let id = ticket["id"].uint
        let client = self.client
        let restoreTimeout = timeouts.sessionRestore
        Task {
            await StackAuthRateLimitReporting.$callerReports.withValue(true) {
                let result: AuthWire
                var readFailed = false
                do {
                    let token = try await runPhase(.validateSession, timeout: restoreTimeout) {
                        await client.refreshToken()
                    }
                    survivingRefreshTokens[id] = token
                    if token == nil, let baseline = restoreReadBaselines[id] {
                        readFailed = await tokenReadFailed(since: baseline)
                    }
                    result = .ok(.bool(token != nil))
                } catch {
                    authLog.error("Session refresh-token check failed: \(error.localizedDescription, privacy: .private)")
                    result = .err(wireFailure(error))
                }
                feed(["survivingRefreshTokenRead": [
                    "ticket": ticket, "afterError": payload["afterError"], "result": result, "readFailed": .bool(readFailed),
                ]])
            }
        }
    }

    private func autoLogin(_ payload: AuthWire) {
        let ticket = payload["ticket"]
        let credentials = payload["source"].string == "environment" ? autoLoginCredentials : debugCredentials
        Task {
            let result: AuthWire
            if let credentials {
                authLog.info("Starting auto-login")
                do {
                    try await signInWithPassword(email: credentials.email, password: credentials.password, setLoading: false)
                    result = .ok()
                } catch {
                    let kind = error as NSError
                    authLog.error("Auto-login failed (\(String(describing: type(of: error)), privacy: .public) \(kind.domain, privacy: .public) \(kind.code, privacy: .public)): \(error.localizedDescription, privacy: .private)")
                    result = .err(wireFailure(error))
                }
            } else {
                result = .err("other")
            }
            feed(["autoLoginFinished": ["ticket": ticket, "result": result]])
        }
    }

    private func finishRestore() {
        restoreInFlight = false
        restoreReadBaselines.removeAll()
        survivingRefreshTokens.removeAll()
        let waiters = restoreWaiters
        restoreWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Sign-in

    private func quiesceTokenWork(_ flow: AuthWire) {
        let attempt = flow["attempt"].uint
        if let requested = requestedSignIn {
            requestedSignIn = nil
            signIns[attempt] = requested
        }
        Task {
            let result: AuthWire
            do {
                try await waitForSessionTokenWorkToQuiesceBeforeSignIn()
                result = .ok()
            } catch {
                signInErrors[attempt] = error
                result = .err(wireFailure(error))
            }
            feed(["tokenWorkQuiesced": ["flow": flow, "result": result]])
        }
    }

    private func runSignInExchange(_ payload: AuthWire) {
        let flow = payload["flow"]
        let attempt = flow["attempt"].uint
        guard let phase = payload["phase"].string.flatMap(AuthPhase.init(rawValue:)),
              let operation = signIns[attempt]?.exchange else {
            feed(["exchangeFinished": ["flow": flow, "result": .err("other")]])
            return
        }
        let timeout = switch payload["budget"].string {
        case "interactive": timeouts.interactiveFlow
        case "sessionRestore": timeouts.sessionRestore
        default: timeouts.network
        }
        Task {
            let result: AuthWire
            do {
                try await runExchange(phase, attempt: attempt, timeout: timeout, operation)
                exchangeRecordedRefreshToken = true
                result = .ok()
            } catch {
                signInErrors[attempt] = error
                result = .err(wireFailure(error))
            }
            feed(["exchangeFinished": ["flow": flow, "result": result]])
        }
    }

    private func fetchSignInUser(_ flow: AuthWire) {
        let attempt = flow["attempt"].uint
        let client = self.client
        Task {
            let result: AuthWire
            do {
                let user = try await runPhase(.fetchUser, timeout: timeouts.network) {
                    try await client.currentUser(throwOnMissing: true)
                }
                result = .ok(user.map { AuthWire(encoding: AuthWireUser($0)) } ?? .null)
            } catch {
                signInErrors[attempt] = error
                result = .err(wireFailure(error))
            }
            feed(["signInUserFetched": ["flow": flow, "result": result]])
        }
    }

    private func failSignIn(flow: AuthWire, failure: AuthWire) {
        let pending: PendingSignIn?
        let raw: (any Error)?
        if flow == .null {
            pending = requestedSignIn
            requestedSignIn = nil
            raw = nil
        } else {
            let attempt = flow["attempt"].uint
            pending = signIns.removeValue(forKey: attempt)
            raw = signInErrors.removeValue(forKey: attempt)
        }
        guard let pending else { return }
        let error = raw ?? Self.authError(failure)
        if pending.kind == "external" {
            lastExternalSignInFailureDetail = AuthError.failureDetail(for: error)
        }
        // A rollback clear queued with this failure lands before the caller hears.
        let clear = lastLocalClear
        Task {
            await clear?.value
            pending.continuation.resume(throwing: AuthError(displaySafe: error) ?? error)
        }
    }

    // MARK: - Teams

    func refreshTeams(ticket: AuthWire) {
        let client = self.client
        let networkTimeout = timeouts.network
        lastTeamRefresh = Task {
            let result: AuthWire
            do {
                // A 429 here is reported by the reducer as a session check.
                let (teams, serverSelectedTeamID) = try await StackAuthRateLimitReporting.$callerReports.withValue(true) {
                    try await runPhase(.listTeams, timeout: networkTimeout) {
                        async let teams = client.listTeams()
                        async let selectedTeamID: String? = try? await client.selectedTeamID()
                        return try await (teams, selectedTeamID)
                    }
                }
                result = .ok(["teams": AuthWire(encoding: teams), "serverSelectedTeamId": AuthWire(serverSelectedTeamID)])
            } catch {
                authLog.error("Failed to list teams: \(error.localizedDescription, privacy: .private)")
                result = .err(wireFailure(error))
            }
            feed(["teamsRefreshed": ["ticket": ticket, "result": result]])
        }
    }

    private func sleepTeamScopeRecovery(id: UInt64, delay: Duration) {
        let clock = self.clock
        teamScopeRecoveryTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(for: delay, tolerance: nil)
            } catch {
                return
            }
            guard let self, teamScopeRecoveryTasks[id] != nil else { return }
            feed(["teamScopeRecoveryDue": ["id": AuthWire(id)]])
            if restoreInFlight {
                await withCheckedContinuation { continuation in
                    guard restoreInFlight else { return continuation.resume() }
                    restoreWaiters.append(continuation)
                }
            }
            teamScopeRecoveryTasks[id] = nil
            feed(["teamScopeRecoveryCheckFinished": ["id": AuthWire(id)]])
        }
    }

    // MARK: - Sign-out

    private func captureTeardownCredentials(_ payload: AuthWire) {
        let epoch = payload["signOutEpoch"]
        let client = self.client
        let dampers = phaseDampersCleared
        Task {
            await dampers?.value
            // Raw stored reads (no refresh, no network) before the clear.
            let accessToken = await client.storedAccessToken()
            let refreshToken = await client.refreshToken()
            pendingSignOut?.capturedTokens = (accessToken, refreshToken)
            latestSignInRefreshToken = nil
            // LOCAL-FIRST: from here the device is signed out no matter what
            // the network does.
            await client.clearLocalSession()
            feed(["signOutLocalCleared": ["signOutEpoch": epoch]])
        }
    }

    private func serverTeardown() {
        guard let signOut = pendingSignOut else { return }
        pendingSignOut = nil
        Task {
            if signOut.waitsForPostSignInHooks {
                await waitForPostSignInHooksAfterSignOut(timeout: signOut.teardownTimeout)
            }
            await runServerTeardown(signOut)
            signOut.continuation.resume()
        }
    }

    /// Best-effort bounded server-side teardown with the captured tokens: the
    /// hook first (the push-token DELETE needs the session to still be valid
    /// server-side), then the Stack session revocation. Structured: on
    /// deadline the group cancels and joins the work child, so it can never
    /// outlive sign-out and interleave with a later sign-in.
    private func runServerTeardown(_ signOut: PendingSignOut) async {
        let client = self.client
        let clock = self.clock
        let log = self.log
        let (accessToken, refreshToken) = signOut.capturedTokens
        let onSignedOut = signOut.onSignedOut
        let teardownTimeout = signOut.teardownTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // The raw capture can hold an expired access token or none at
                // all; mint one from the captured refresh token when needed,
                // never touching the cleared live store.
                var teardownAccessToken = accessToken
                if let refreshToken {
                    teardownAccessToken = await client.freshAccessToken(
                        accessToken: accessToken,
                        refreshToken: refreshToken
                    ) ?? accessToken
                }
                // The mint swallows cancellation into `nil`; re-check before each leg.
                guard !Task.isCancelled else {
                    log.log("auth.signOut teardown deadline hit before the sign-out hook; server teardown skipped")
                    return
                }
                await onSignedOut(teardownAccessToken, refreshToken)
                guard !Task.isCancelled else {
                    log.log("auth.signOut teardown deadline hit before revocation; server session left unrevoked")
                    return
                }
                do {
                    try await client.revokeSession(accessToken: teardownAccessToken, refreshToken: refreshToken)
                } catch {
                    // Best-effort by design. The public sink gets only the error TYPE.
                    authLog.error("Sign-out session revocation failed: \(error.localizedDescription, privacy: .private)")
                    log.log("auth.signOut revocation failed: \(String(describing: type(of: error)))")
                }
            }
            group.addTask {
                try? await clock.sleep(for: teardownTimeout, tolerance: nil)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Failures

    /// The reducer's name for a failure. A 429 keeps its ``AuthRateLimit`` for
    /// the telemetry record the reducer may ask for next.
    func wireFailure(_ error: any Error) -> AuthWire {
        if let limit = AuthRateLimit(error: error) {
            lastRateLimit = limit
            return ["rateLimited": ["retryAfter": AuthWire(milliseconds: limit.retryAfter)]]
        }
        if error is CancellationError { return "cancelled" }
        switch AuthError(displaySafe: error) {
        case .cancelled: return "cancelled"
        case .timedOut: return "timedOut"
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .invalidCode: return "invalidCode"
        case .rateLimited: return ["rateLimited": ["retryAfter": nil]]
        case nil: return "other"
        default: return "networkError"
        }
    }

    static func authError(_ failure: AuthWire) -> AuthError {
        switch failure.variant.tag {
        case "cancelled": .cancelled
        case "timedOut": .timedOut
        case "offline": .offline
        case "unauthorized": .unauthorized
        case "invalidCode": .invalidCode
        case "rateLimited": .rateLimited
        default: .networkError
        }
    }
}
