public import Foundation
import OSLog

private let pushLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

private func pendingUnregisterOverflowPageKey(
    accountID: String,
    page: Int
) -> String {
    let base = "cmux.notifications.pendingUnregisters.v4.overflow.\(accountID)"
    return page == 0 ? base : "\(base).page\(page)"
}

private func pendingUnregisterOverflowPageCountKey(accountID: String) -> String {
    "cmux.notifications.pendingUnregisters.v4.overflowPages.\(accountID)"
}

private func pendingUnregisterOverflowTokenIndexPageKey(
    tokenHex: String,
    page: Int
) -> String {
    let base = "cmux.notifications.pendingUnregisters.v4.token.\(tokenHex)"
    return page == 0 ? base : "\(base).page\(page)"
}

private func pendingUnregisterOverflowTokenIndexPageCountKey(
    tokenHex: String
) -> String {
    "cmux.notifications.pendingUnregisters.v4.tokenPages.\(tokenHex)"
}

/// Owns the push opt-in state and the device-token sync with the cmux web API.
///
/// Replaces the iOS `NotificationManager.shared` singleton and its
/// `AuthManager.shared` / `AppEnvironment.current` reach-ins: construct it once
/// at the app composition root with an injected ``TokenProviding``, API base
/// URL, bundle id, `UserDefaults(suiteName:)`, and `URLSession`, then inject it
/// as `any PushRegistering`.
///
/// Privacy: nothing (not even a device token) is uploaded until the app's
/// workspace-list permission flow is accepted or the user explicitly enables
/// notifications and the coordinator calls ``setEnabled(_:)``. An explicit
/// app opt-out remains persisted and authoritative.
public actor PushRegistrationService: PushRegistering {
    private let tokenProvider: any TokenProviding
    private let apiBaseURL: String
    private let bundleID: String
    private let apnsEnvironment: String
    private let defaults: UserDefaults
    private let session: URLSession
    private let retryDelays: [Duration]
    private let retryJitter: @Sendable (ClosedRange<Double>) -> Double
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let sessionSnapshotTimeout: Duration
    private let sessionSnapshotClock: any Clock<Duration>
    private let sessionSnapshotTimeoutRegistry = AuthPhaseTimeoutRegistry()
    private let authLog = AuthDebugLog()
    private var retryTask: Task<Void, Never>?
    private var unregisterDrainTask: Task<Void, Never>?
    /// App-lifetime, direction-owned workers let a privacy-sensitive opt-out
    /// proceed while an older registration request is still in flight. One
    /// stored task per direction bounds concurrency during rapid toggling.
    private var enableIntentReconciliationTask: Task<Void, Never>?
    private var disableIntentReconciliationTask: Task<Void, Never>?
    private var enableIntentReconciliationRequested = false
    private var disableIntentReconciliationRequested = false
    private var coordinatorIntentGeneration: UInt64 = 0
    private var coordinatorIntentEnabled: Bool?

    // Actor reentrancy lets a second lifecycle callback enter while the first
    // POST is suspended in URLSession. Keep one in-flight upload per token so
    // foreground refresh, auth revalidation, and APNs callbacks cannot create
    // duplicate writes. A different token, or a deliberately superseding
    // operation after stale-session reconciliation, gets its own generation.
    private var uploadTask: Task<Void, Never>?
    private var uploadTaskTokenHex: String?
    private var uploadTaskGeneration: UUID?
    private var uploadTaskAccountID: String?
    private var operationGeneration = UUID()
    private var snapshotValue: PushRegistrationSnapshot
    private var snapshotContinuations:
        [UUID: AsyncStream<PushRegistrationSnapshot>.Continuation] = [:]

    private static let enabledKey = "cmux.notifications.pushEnabled"
    private static let cachedTokenKey = "cmux.notifications.deviceTokenHex"
    private static let registeredAccountIDKey = "cmux.notifications.registeredAccountID"
    private static let pendingUnregisterTokenKey = "cmux.notifications.pendingUnregisterToken"
    private static let pendingUnregisterAccountIDKey = "cmux.notifications.pendingUnregisterAccountID"
    private static let pendingUnregisterQueueKey =
        "cmux.notifications.pendingUnregisters.v2"
    private static let pendingUnregisterOverflowCountKey =
        "cmux.notifications.pendingUnregisterOverflowCount.v4"
    private static let pendingUnregisterAttemptBudget = 4
    private static let pendingUnregisterActiveLimit = 200
    private static let pendingUnregisterOverflowPageSize = 200

    /// Creates a push registration service.
    ///
    /// - Parameters:
    ///   - tokenProvider: Supplies the access/refresh tokens for authenticated
    ///     API calls (production: ``AuthCoordinator``).
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash).
    ///   - bundleID: The app bundle identifier sent with the device token.
    ///   - apnsEnvironment: `"sandbox"` for DEBUG builds, `"production"` otherwise.
    ///   - suiteName: The `UserDefaults(suiteName:)` for the opt-in flag + last
    ///     device token. `nil` uses `.standard`. The suite is opened inside the
    ///     actor so callers never send a non-`Sendable` `UserDefaults` across
    ///     the isolation boundary.
    ///   - session: The URLSession used for API calls.
    public init(
        tokenProvider: any TokenProviding,
        apiBaseURL: String,
        bundleID: String,
        apnsEnvironment: String,
        suiteName: String? = nil,
        session: sending URLSession = .shared,
        retryDelays: [Duration] = [
            .seconds(1),
            .seconds(4),
            .seconds(15),
            .seconds(60),
        ],
        retryJitter: @escaping @Sendable (ClosedRange<Double>) -> Double = {
            Double.random(in: $0)
        },
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        },
        sessionSnapshotTimeout: Duration = .seconds(15),
        sessionSnapshotClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.tokenProvider = tokenProvider
        self.apiBaseURL = apiBaseURL
        self.bundleID = bundleID
        self.apnsEnvironment = apnsEnvironment
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        Self.migrateLegacyPendingUnregisters(in: self.defaults)
        self.session = session
        self.retryDelays = retryDelays
        self.retryJitter = retryJitter
        self.retrySleep = retrySleep
        self.sessionSnapshotTimeout = sessionSnapshotTimeout
        self.sessionSnapshotClock = sessionSnapshotClock
        let enabled = self.defaults.bool(forKey: Self.enabledKey)
        let hasToken = self.defaults.string(forKey: Self.cachedTokenKey)?.isEmpty == false
        self.snapshotValue = PushRegistrationSnapshot(
            isEnabled: enabled,
            hasDeviceToken: hasToken,
            backendState: enabled
                ? (hasToken ? .registrationRequired : .awaitingDeviceToken)
                : .awaitingDeviceToken
        )
    }

    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    public var snapshot: PushRegistrationSnapshot { snapshotValue }

    public func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        let id = UUID()
        let hasKnownRegistration = cachedTokenHex != nil
            && defaults.string(
                forKey: Self.registeredAccountIDKey
            )?.isEmpty == false
        if !isEnabled,
           !pendingUnregisters.isEmpty
               || pendingUnregisterOverflowCount > 0
               || hasKnownRegistration {
            coordinatorIntentEnabled = false
            disableIntentReconciliationRequested = true
            scheduleDisableIntentReconciliation()
        }
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(snapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        // The UI commits the shared preference before crossing into this actor.
        // Snapshot state therefore carries the prior service intent needed to
        // decide whether an opt-out still owes backend cleanup.
        let owesBackendCleanup = snapshotValue.isEnabled
            || defaults.string(forKey: Self.registeredAccountIDKey) != nil
        cancelRetry()
        let generation = operationGeneration
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            await syncTokenIfPossible()
        } else {
            publish(.disabled)
            if owesBackendCleanup {
                await unregisterFromServer(
                    preferenceGeneration: generation
                )
            } else {
                await retryPendingUnregisterIfPossible(
                    preferenceGeneration: generation
                )
            }
        }
    }

    /// Commits the coordinator's latest preference immediately. Disable starts
    /// durable backend cleanup now; enable waits for the coordinator's separate
    /// post-authorization reconciliation call.
    public func applyEnabledIntent(
        _ enabled: Bool,
        generation: UInt64
    ) async {
        guard generation >= coordinatorIntentGeneration else { return }
        if generation == coordinatorIntentGeneration,
           coordinatorIntentEnabled == enabled {
            return
        }
        coordinatorIntentGeneration = generation
        coordinatorIntentEnabled = enabled
        cancelRetry()
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            let hasToken = cachedTokenHex != nil
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: hasToken,
                backendState: hasToken
                    ? .registrationRequired
                    : .awaitingDeviceToken
            ))
        } else {
            if let tokenHex = cachedTokenHex,
               let accountID = defaults.string(
                   forKey: Self.registeredAccountIDKey
               ),
               !accountID.isEmpty {
                // Persist the cleanup before the worker can suspend on auth.
                persistPendingUnregister(
                    tokenHex: tokenHex,
                    accountID: accountID
                )
            }
            publish(.disabled)
        }
        if !enabled {
            disableIntentReconciliationRequested = true
            scheduleDisableIntentReconciliation()
        }
    }

    /// Reconciles an enabled intent only after iOS authorization has succeeded.
    /// Stale generations cannot upload a cached APNs token.
    public func reconcileEnabledIntent(generation: UInt64) async {
        guard generation == coordinatorIntentGeneration,
              coordinatorIntentEnabled == true,
              isEnabled else { return }
        enableIntentReconciliationRequested = true
        scheduleEnableIntentReconciliation()
    }

    private func scheduleEnableIntentReconciliation() {
        guard enableIntentReconciliationTask == nil else { return }
        enableIntentReconciliationTask = Task { [weak self] in
            await self?.drainEnableIntentReconciliation()
        }
    }

    private func drainEnableIntentReconciliation() async {
        while enableIntentReconciliationRequested {
            enableIntentReconciliationRequested = false
            guard coordinatorIntentEnabled == true else { continue }
            await syncTokenIfPossible()
        }
        enableIntentReconciliationTask = nil
        if enableIntentReconciliationRequested {
            scheduleEnableIntentReconciliation()
        }
    }

    private func scheduleDisableIntentReconciliation() {
        guard disableIntentReconciliationTask == nil else { return }
        disableIntentReconciliationTask = Task { [weak self] in
            await self?.drainDisableIntentReconciliation()
        }
    }

    private func drainDisableIntentReconciliation() async {
        while disableIntentReconciliationRequested {
            disableIntentReconciliationRequested = false
            guard coordinatorIntentEnabled == false else { continue }
            let generation = coordinatorIntentGeneration
            let preferenceGeneration = operationGeneration
            await unregisterFromServer(
                preferenceGeneration: preferenceGeneration
            )
            await retryPendingUnregisterIfPossible(
                preferenceGeneration: preferenceGeneration
            )
            guard generation == coordinatorIntentGeneration,
                  coordinatorIntentEnabled == false else { continue }
            publish(.disabled)
        }
        disableIntentReconciliationTask = nil
        if disableIntentReconciliationRequested {
            scheduleDisableIntentReconciliation()
        }
    }

    public func register(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previousToken = cachedTokenHex
        if let previousToken,
           previousToken != hex,
           let previousOwner = defaults.string(
               forKey: Self.registeredAccountIDKey
           ),
           !previousOwner.isEmpty {
            // Rotation does not prove the old row disappeared. Preserve its
            // cleanup before replacing the cache, then make the new token
            // ready before attempting the old-token DELETE.
            persistPendingUnregister(
                tokenHex: previousToken,
                accountID: previousOwner
            )
            defaults.removeObject(forKey: Self.registeredAccountIDKey)
        }
        defaults.set(hex, forKey: Self.cachedTokenKey)
        guard isEnabled else {
            publish(.disabled)
            return
        }
        // A repeated callback for the same cached token should cancel only a
        // pending backoff, not invalidate the already-running POST. A rotated
        // token is a genuinely new operation and invalidates the old one.
        let tokenChanged = previousToken != nil && previousToken != hex
        cancelRetry(invalidateOperation: tokenChanged)
        await upload(tokenHex: hex)
        if snapshotValue.backendState == .registered {
            await retryPendingUnregisterIfPossible()
        }
    }

    public func syncTokenIfPossible() async {
        guard isEnabled else {
            await retryPendingUnregisterIfPossible()
            publish(.disabled)
            return
        }
        guard let hex = cachedTokenHex else {
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: false,
                backendState: .awaitingDeviceToken
            ))
            // There is no current registration to prioritize, so an
            // owner-matching privacy cleanup can proceed immediately.
            await retryPendingUnregisterIfPossible()
            return
        }
        // A repeated lifecycle validation should cancel only a pending
        // backoff, not invalidate the already-running POST. `upload` then
        // coalesces the same-token operation.
        cancelRetry(invalidateOperation: false)
        await upload(tokenHex: hex)
        // Current-account registration is the readiness-critical operation.
        // Historical cleanup follows it, with its own bounded attempt budget.
        if snapshotValue.backendState == .registered {
            await retryPendingUnregisterIfPossible()
        }
    }

    public func unregisterFromServer() async {
        await unregisterFromServer(preferenceGeneration: nil)
    }

    private func unregisterFromServer(
        preferenceGeneration: UUID?
    ) async {
        if preferenceGeneration == nil {
            cancelRetry()
        }
        guard let hex = cachedTokenHex else { return }
        let registeredOwnerID = defaults.string(
            forKey: Self.registeredAccountIDKey
        )
        if let registeredOwnerID, !registeredOwnerID.isEmpty {
            // Record the privacy cleanup before any authentication await. A
            // stalled session restore must not lose an already-known owner.
            persistPendingUnregister(
                tokenHex: hex,
                accountID: registeredOwnerID
            )
        }
        let session = await boundedSessionSnapshot(
            phase: .pushUnregistrationSession
        )
        if let preferenceGeneration,
           preferenceGeneration != operationGeneration || isEnabled {
            return
        }
        let ownerID = registeredOwnerID ?? session?.accountID
        guard let ownerID, !ownerID.isEmpty else { return }
        // Persist before requiring live auth. This is the privacy guarantee for
        // an offline or signed-out opt-out.
        persistPendingUnregister(tokenHex: hex, accountID: ownerID)
        // A token acknowledged for account A must never be deleted using
        // account B credentials. Its tombstone waits for A to return.
        guard let session, session.accountID == ownerID else { return }
        if await sendDelete(tokenHex: hex, sessionSnapshot: session) {
            clearPendingUnregister(tokenHex: hex, accountID: ownerID)
            clearRegisteredOwner(accountID: ownerID, tokenHex: hex)
            if let preferenceGeneration,
               preferenceGeneration != operationGeneration || isEnabled,
               isEnabled,
               cachedTokenHex == hex {
                // A newer enable may have posted while this older DELETE was
                // already in flight. Re-upsert after the DELETE acknowledgement
                // so the latest preference is also the final backend state.
                await upload(tokenHex: hex)
            }
        }
    }

    /// Delete the device token from the server at sign-out, authenticating
    /// with the credentials captured before the local-first clear destroyed
    /// the live session.
    ///
    /// - Parameters:
    ///   - accessToken: The captured (or teardown-minted) access token.
    ///   - refreshToken: The captured refresh token.
    public func unregisterFromServer(accessToken: String?, refreshToken: String?) async {
        await unregisterFromServer(
            accountID: nil,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    /// Sign-out variant with the account id captured before local auth clear.
    public func unregisterFromServer(
        accountID capturedAccountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {
        cancelRetry()
        guard let hex = cachedTokenHex else { return }
        let registeredOwnerID = defaults.string(
            forKey: Self.registeredAccountIDKey
        )
        let ownerID = registeredOwnerID ?? capturedAccountID
        if let ownerID, !ownerID.isEmpty {
            // Persist the recovery record before validating credentials.
            // Offline sign-out commonly has only the refresh token, but a
            // later sign-in to this same account can safely finish the DELETE.
            persistPendingUnregister(tokenHex: hex, accountID: ownerID)
        }
        if let registeredOwnerID,
           capturedAccountID != registeredOwnerID {
            // The legacy overload has no account identity, and a caller
            // explicitly carrying B must never apply B's credentials to A's
            // acknowledged token. Keep A's tombstone until A returns.
            pushLog.info("Skipping push-token unregister: captured account does not prove registered ownership")
            return
        }
        // Sign-out path: never fall back to the live token provider. The
        // local-first sign-out cleared it, and a sign-in racing the bounded
        // teardown can repopulate it with the NEXT account's tokens; the
        // DELETE must authenticate as the signing-out account or not run at
        // all. An incomplete pair means the access-token mint failed
        // (offline), where the DELETE could not have succeeded anyway.
        guard let accessToken, let refreshToken else {
            pushLog.info("Skipping push-token unregister at sign-out: captured credentials incomplete")
            return
        }
        if await sendDelete(
            tokenHex: hex,
            capturedAccessToken: accessToken,
            capturedRefreshToken: refreshToken
        ), let ownerID {
            clearPendingUnregister(tokenHex: hex, accountID: ownerID)
            clearRegisteredOwner(accountID: ownerID, tokenHex: hex)
        }
        if isEnabled {
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .registrationRequired
            ))
        }
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    private func upload(
        tokenHex: String,
        replacingGeneration: UUID? = nil
    ) async {
        let requestedAccountID = (try? await tokenProvider
            .authenticatedSessionSnapshot())?.accountID
        if let uploadTask,
           uploadTaskTokenHex == tokenHex,
           uploadTaskGeneration == operationGeneration,
           uploadTaskGeneration != replacingGeneration,
           uploadTaskAccountID == requestedAccountID {
            await uploadTask.value
            return
        }
        operationGeneration = UUID()
        let generation = operationGeneration
        let retryDelays = self.retryDelays
        let task = Task { [weak self, retryDelays] in
            guard let self else { return }
            await self.attemptUpload(
                tokenHex: tokenHex,
                generation: generation,
                remainingDelays: retryDelays
            )
        }
        uploadTask = task
        uploadTaskTokenHex = tokenHex
        uploadTaskGeneration = generation
        uploadTaskAccountID = requestedAccountID
        await task.value
        if uploadTaskGeneration == generation {
            uploadTask = nil
            uploadTaskTokenHex = nil
            uploadTaskGeneration = nil
            uploadTaskAccountID = nil
        }
    }

    private func attemptUpload(
        tokenHex: String,
        generation: UUID,
        remainingDelays: [Duration]
    ) async {
        guard isEnabled, generation == operationGeneration,
              cachedTokenHex == tokenHex else { return }
        publish(PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: true,
            backendState: .registering
        ))
        let request = await makeRequest(
            method: "POST",
            path: "/api/device-tokens",
            body: [
                "deviceToken": tokenHex,
                "bundleId": bundleID,
                "environment": apnsEnvironment,
                "platform": "ios",
            ],
            authPhase: .pushRegistrationSession
        )
        let result: RegistrationResult
        let requestSession: AuthenticatedSessionSnapshot?
        switch request {
        case let .success(context):
            requestSession = context.session
            result = await performRegistration(context.request)
        case let .failure(failure):
            requestSession = nil
            result = .failure(failure, retryAfter: nil)
        }
        let operationIsCurrent = isEnabled
            && generation == operationGeneration
            && cachedTokenHex == tokenHex
        let sessionIsCurrent: Bool
        if let requestSession {
            sessionIsCurrent = await tokenProvider
                .isAuthenticatedSessionCurrent(requestSession)
        } else {
            sessionIsCurrent = false
        }
        if case .success = result,
           let requestSession,
           (!operationIsCurrent || !sessionIsCurrent) {
            await reconcileStaleSuccessfulRegistration(
                tokenHex: tokenHex,
                staleSession: requestSession,
                staleGeneration: generation
            )
            return
        }
        guard operationIsCurrent else { return }
        if requestSession != nil, !sessionIsCurrent {
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .failed(.authenticationRequired)
            ))
            return
        }
        switch result {
        case let .success(pushServiceConfigured):
            let previousOwnerID = defaults.string(
                forKey: Self.registeredAccountIDKey
            )
            if let requestSession {
                defaults.set(
                    requestSession.accountID,
                    forKey: Self.registeredAccountIDKey
                )
            }
            // The token is globally unique. A successful upsert onto the
            // current account also removes any old-account association, so a
            // pending tombstone for this token is fulfilled without applying
            // old credentials.
            if previousOwnerID != nil || pendingUnregisters.contains(
                where: { $0.tokenHex == tokenHex }
            ) || pendingUnregisterOverflowCount > 0 {
                clearPendingUnregisterToken(tokenHex: tokenHex)
            }
            if pushServiceConfigured {
                publish(PushRegistrationSnapshot(
                    isEnabled: true,
                    hasDeviceToken: true,
                    backendState: .registered
                ))
            } else {
                // The API committed ownership before reporting its provider
                // readiness. Retain that cleanup identity while failing the
                // user-facing readiness check closed and retrying recovery.
                let failure = PushRegistrationFailure.serviceUnavailable
                publish(PushRegistrationSnapshot(
                    isEnabled: true,
                    hasDeviceToken: true,
                    backendState: .failed(failure)
                ))
                scheduleUploadRetry(
                    failure: failure,
                    retryAfter: nil,
                    tokenHex: tokenHex,
                    generation: generation,
                    remainingDelays: remainingDelays
                )
            }
        case let .failure(failure, retryAfter):
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .failed(failure)
            ))
            scheduleUploadRetry(
                failure: failure,
                retryAfter: retryAfter,
                tokenHex: tokenHex,
                generation: generation,
                remainingDelays: remainingDelays
            )
        }
    }

    private func scheduleUploadRetry(
        failure: PushRegistrationFailure,
        retryAfter: Duration?,
        tokenHex: String,
        generation: UUID,
        remainingDelays: [Duration]
    ) {
        guard failure.isRecoverable, !remainingDelays.isEmpty else { return }
        let fallbackDelay = remainingDelays[0]
        let delay = retryAfter ?? Self.jittered(
            fallbackDelay,
            multiplier: retryJitter(0.8...1.2)
        )
        let laterDelays = Array(remainingDelays.dropFirst())
        retryTask = Task { [weak self, retrySleep] in
            do {
                try await retrySleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.attemptUpload(
                tokenHex: tokenHex,
                generation: generation,
                remainingDelays: laterDelays
            )
        }
    }

    /// Repairs the backend after an invalidated POST still succeeds.
    ///
    /// URLSession cancellation cannot prove that the server did not commit the
    /// request. Delete with the exact stale account credentials after its
    /// acknowledgement, then re-upsert the token for whichever account is
    /// current now. This orders A POST, A DELETE, B POST and therefore makes B
    /// the final owner even when A's response arrives last.
    private func reconcileStaleSuccessfulRegistration(
        tokenHex: String,
        staleSession: AuthenticatedSessionSnapshot,
        staleGeneration: UUID
    ) async {
        let currentSession = await boundedSessionSnapshot(
            phase: .pushRegistrationSession
        )
        if isEnabled,
           cachedTokenHex == tokenHex,
           currentSession?.accountID == staleSession.accountID {
            // A newer operation for the same account and token already
            // represents the same backend ownership. Do not disturb it.
            return
        }

        persistPendingUnregister(
            tokenHex: tokenHex,
            accountID: staleSession.accountID
        )
        if await sendDelete(
            tokenHex: tokenHex,
            capturedAccessToken: staleSession.accessToken,
            capturedRefreshToken: staleSession.refreshToken
        ) {
            clearPendingUnregister(
                tokenHex: tokenHex,
                accountID: staleSession.accountID
            )
            clearRegisteredOwner(
                accountID: staleSession.accountID,
                tokenHex: tokenHex
            )
        }

        guard isEnabled, let currentToken = cachedTokenHex,
              let currentSession = await boundedSessionSnapshot(
                  phase: .pushRegistrationSession
              ),
              await tokenProvider.isAuthenticatedSessionCurrent(currentSession)
        else { return }
        await upload(tokenHex: currentToken, replacingGeneration: staleGeneration)
    }

    private func sendDelete(
        tokenHex: String,
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil,
        sessionSnapshot: AuthenticatedSessionSnapshot? = nil
    ) async -> Bool {
        guard case let .success(context) = await makeRequest(
            method: "DELETE",
            path: "/api/device-tokens",
            body: ["deviceToken": tokenHex],
            capturedAccessToken: capturedAccessToken,
            capturedRefreshToken: capturedRefreshToken,
            sessionSnapshot: sessionSnapshot,
            authPhase: .pushUnregistrationSession
        ) else { return false }
        guard await performDelete(context.request) else { return false }
        if let session = context.session {
            return await tokenProvider.isAuthenticatedSessionCurrent(session)
        }
        return true
    }

    private func makeRequest(
        method: String,
        path: String,
        body: [String: String],
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil,
        sessionSnapshot: AuthenticatedSessionSnapshot? = nil,
        authPhase: AuthPhase
    ) async -> Result<PushRequest, PushRegistrationFailure> {
        let accessToken: String
        let refreshToken: String
        let authenticatedSession: AuthenticatedSessionSnapshot?
        if let sessionSnapshot {
            accessToken = sessionSnapshot.accessToken
            refreshToken = sessionSnapshot.refreshToken
            authenticatedSession = sessionSnapshot
        } else if let capturedAccessToken, let capturedRefreshToken {
            // Sign-out path: the live provider is already cleared by the
            // local-first sign-out; the captured pair is the only credential.
            accessToken = capturedAccessToken
            refreshToken = capturedRefreshToken
            authenticatedSession = nil
        } else {
            guard let session = await boundedSessionSnapshot(
                phase: authPhase
            ) else {
                return .failure(.authenticationRequired)
            }
            accessToken = session.accessToken
            refreshToken = session.refreshToken
            authenticatedSession = session
        }
        guard let url = URL(string: apiBaseURL + path) else {
            return .failure(.invalidConfiguration)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        return .success(PushRequest(
            request: request,
            session: authenticatedSession
        ))
    }

    private func performRegistration(_ request: URLRequest) async -> RegistrationResult {
        let redirectDelegate = RedirectMethodPreservingDelegate()
        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: redirectDelegate
            )
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidServerResponse, retryAfter: nil)
            }
            guard (200...299).contains(http.statusCode) else {
                return Self.failureResult(statusCode: http.statusCode, response: http, data: data)
            }
            guard let acknowledgement = try? JSONDecoder().decode(
                RegistrationAcknowledgement.self,
                from: data
            ), acknowledgement.ok else {
                return .failure(.invalidServerResponse, retryAfter: nil)
            }
            return .success(
                pushServiceConfigured:
                    acknowledgement.pushServiceConfigured != false
            )
        } catch {
            if redirectDelegate.refusedRedirect {
                return .failure(.invalidServerResponse, retryAfter: nil)
            }
            pushLog.error("register transport failure")
            return .failure(.networkUnavailable, retryAfter: nil)
        }
    }

    private func performDelete(_ request: URLRequest) async -> Bool {
        let redirectDelegate = RedirectMethodPreservingDelegate()
        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: redirectDelegate
            )
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                pushLog.error(
                    "unregister failed status=\(http.statusCode, privacy: .public)"
                )
                return false
            }
            guard response is HTTPURLResponse,
                  let acknowledgement = try? JSONDecoder().decode(
                      RegistrationAcknowledgement.self,
                      from: data
                  ),
                  acknowledgement.ok
            else {
                pushLog.error("unregister acknowledgement invalid")
                return false
            }
            return true
        } catch {
            pushLog.error("unregister transport failure")
            return false
        }
    }

    private func retryPendingUnregisterIfPossible(
        preferenceGeneration: UUID? = nil
    ) async {
        guard let session = await boundedSessionSnapshot(
            phase: .pushUnregistrationSession
        ) else { return }
        if let preferenceGeneration,
           preferenceGeneration != operationGeneration || isEnabled {
            return
        }
        let currentAccountID = session.accountID
        var seen = Set<PendingUnregister>()
        let matching = (
            pendingUnregisters.filter { $0.accountID == currentAccountID }
                + pendingUnregisterOverflowBatch(
                    accountID: currentAccountID,
                    limit: Self.pendingUnregisterAttemptBudget
                )
        ).filter {
            seen.insert($0).inserted
        }
        let batch = Array(
            matching.prefix(Self.pendingUnregisterAttemptBudget)
        )
        let results = await withTaskGroup(
            of: (PendingUnregister, Bool).self,
            returning: [(PendingUnregister, Bool)].self
        ) { group in
            for pending in batch {
                group.addTask { [self] in
                    (
                        pending,
                        await sendDelete(
                            tokenHex: pending.tokenHex,
                            sessionSnapshot: session
                        )
                    )
                }
            }
            var results: [(PendingUnregister, Bool)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for (pending, succeeded) in results where succeeded {
            clearPendingUnregister(
                tokenHex: pending.tokenHex,
                accountID: pending.accountID
            )
            clearRegisteredOwner(
                accountID: pending.accountID,
                tokenHex: pending.tokenHex
            )
        }
        let preferenceWasSuperseded = preferenceGeneration.map {
            $0 != operationGeneration || isEnabled
        } ?? false
        if preferenceWasSuperseded,
           isEnabled,
           let currentToken = cachedTokenHex,
           results.contains(where: {
               $0.0.tokenHex == currentToken && $0.1
           }) {
            // A newer enable raced cleanup that was already sent. Restore the
            // current token only after every acknowledged DELETE has finished.
            await upload(tokenHex: currentToken)
            return
        }
        guard !preferenceWasSuperseded else { return }
        if matching.count > batch.count,
           results.contains(where: { $0.1 }) {
            schedulePendingUnregisterContinuation()
        }
    }

    private func boundedSessionSnapshot(
        phase: AuthPhase
    ) async -> AuthenticatedSessionSnapshot? {
        let tokenProvider = tokenProvider
        return try? await withAuthPhaseTimeout(
            phase,
            duration: sessionSnapshotTimeout,
            clock: sessionSnapshotClock,
            log: authLog,
            registry: sessionSnapshotTimeoutRegistry,
            blocksRetriesWhileTimedOutOperationActive: true
        ) {
            // This provider API only reads a coherent stored token pair or
            // awaits bounded launch bootstrap. Cancelling it cannot leave an
            // ambiguous server mutation behind.
            try await tokenProvider.authenticatedSessionSnapshot()
        }
    }

    private func persistPendingUnregister(tokenHex: String, accountID: String) {
        let entry = PendingUnregister(tokenHex: tokenHex, accountID: accountID)
        var queue = pendingUnregisters
        queue.removeAll { $0 == entry }
        removePendingUnregisterOverflow(entry)
        queue.append(entry)
        storePendingUnregisters(queue)
    }

    private func schedulePendingUnregisterContinuation() {
        guard unregisterDrainTask == nil else { return }
        unregisterDrainTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.runPendingUnregisterContinuation()
        }
    }

    private func runPendingUnregisterContinuation() async {
        unregisterDrainTask = nil
        await retryPendingUnregisterIfPossible()
    }

    private func clearPendingUnregister(
        tokenHex: String,
        accountID: String
    ) {
        let filtered = pendingUnregisters.filter { entry in
            entry.tokenHex != tokenHex || entry.accountID != accountID
        }
        storePendingUnregisters(filtered)
        removePendingUnregisterOverflow(
            tokenHex: tokenHex,
            accountID: accountID
        )
    }

    private var pendingUnregisters: [PendingUnregister] {
        let entries: [PendingUnregister]
        if let data = defaults.data(forKey: Self.pendingUnregisterQueueKey),
           let decoded = try? JSONDecoder().decode(
               [PendingUnregister].self,
               from: data
           ) {
            entries = decoded
        } else {
            entries = []
        }
        var seen = Set<PendingUnregister>()
        return entries.filter { seen.insert($0).inserted }
    }

    private static func migrateLegacyPendingUnregisters(
        in defaults: UserDefaults
    ) {
        var entries = (defaults.data(forKey: pendingUnregisterQueueKey)
            .flatMap { try? JSONDecoder().decode(
                [PendingUnregister].self,
                from: $0
            ) }) ?? []
        if let tokenHex = defaults.string(
            forKey: pendingUnregisterTokenKey
        ), let accountID = defaults.string(
            forKey: pendingUnregisterAccountIDKey
        ), !tokenHex.isEmpty, !accountID.isEmpty {
            let legacy = PendingUnregister(
                tokenHex: tokenHex,
                accountID: accountID
            )
            entries.removeAll { $0 == legacy }
            entries.append(legacy)
        }
        var seen = Set<PendingUnregister>()
        var newestFirst: [PendingUnregister] = []
        for entry in entries.reversed() where seen.insert(entry).inserted {
            newestFirst.append(entry)
        }
        let normalized = Array(newestFirst.reversed())
        let overflowCount = max(
            0,
            normalized.count - pendingUnregisterActiveLimit
        )
        let overflow = normalized.prefix(overflowCount)
        for entry in overflow {
            appendPendingUnregisterOverflow(entry, in: defaults)
        }
        let active = Array(normalized.suffix(pendingUnregisterActiveLimit))
        if active.isEmpty {
            defaults.removeObject(forKey: pendingUnregisterQueueKey)
        } else if let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: pendingUnregisterQueueKey)
        }
        defaults.removeObject(forKey: pendingUnregisterTokenKey)
        defaults.removeObject(forKey: pendingUnregisterAccountIDKey)
    }

    private func storePendingUnregisters(_ entries: [PendingUnregister]) {
        var seen = Set<PendingUnregister>()
        var newestFirst: [PendingUnregister] = []
        for entry in entries.reversed() where seen.insert(entry).inserted {
            newestFirst.append(entry)
        }
        let normalized = Array(newestFirst.reversed())
        let overflowCount = max(
            0,
            normalized.count - Self.pendingUnregisterActiveLimit
        )
        let overflow = normalized.prefix(overflowCount)
        for entry in overflow {
            appendPendingUnregisterOverflow(entry)
        }
        let active = Array(
            normalized.suffix(Self.pendingUnregisterActiveLimit)
        )
        if active.isEmpty {
            defaults.removeObject(forKey: Self.pendingUnregisterQueueKey)
            defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
            defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
            return
        }
        if let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: Self.pendingUnregisterQueueKey)
        }
        defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
        defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
    }

    private var pendingUnregisterOverflowCount: Int {
        defaults.integer(forKey: Self.pendingUnregisterOverflowCountKey)
    }

    private static func decodeOverflowPage(
        accountID: String,
        page: Int,
        defaults: UserDefaults
    ) -> [PendingUnregister] {
        guard let data = defaults.data(
            forKey: pendingUnregisterOverflowPageKey(
                accountID: accountID,
                page: page
            )
        ), let decoded = try? JSONDecoder().decode(
            [PendingUnregister].self,
            from: data
        ) else { return [] }
        var seen = Set<PendingUnregister>()
        return Array(decoded.filter { seen.insert($0).inserted }.prefix(
            pendingUnregisterOverflowPageSize
        ))
    }

    private static func storeOverflowPage(
        _ entries: [PendingUnregister],
        accountID: String,
        page: Int,
        defaults: UserDefaults
    ) {
        let key = pendingUnregisterOverflowPageKey(
            accountID: accountID,
            page: page
        )
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(
            Array(entries.prefix(pendingUnregisterOverflowPageSize))
        ) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decodeTokenIndexPage(
        tokenHex: String,
        page: Int,
        defaults: UserDefaults
    ) -> [String] {
        guard let data = defaults.data(
            forKey: pendingUnregisterOverflowTokenIndexPageKey(
                tokenHex: tokenHex,
                page: page
            )
        ), let decoded = try? JSONDecoder().decode(
            [String].self,
            from: data
        ) else { return [] }
        return Array(decoded.prefix(pendingUnregisterOverflowPageSize))
    }

    private static func storeTokenIndexPage(
        _ entries: [String],
        tokenHex: String,
        page: Int,
        defaults: UserDefaults
    ) {
        let key = pendingUnregisterOverflowTokenIndexPageKey(
            tokenHex: tokenHex,
            page: page
        )
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(
            Array(entries.prefix(pendingUnregisterOverflowPageSize))
        ) {
            defaults.set(data, forKey: key)
        }
    }

    private static func incrementOverflowCount(
        by delta: Int,
        defaults: UserDefaults
    ) {
        let total = max(
            0,
            defaults.integer(forKey: pendingUnregisterOverflowCountKey) + delta
        )
        if total == 0 {
            defaults.removeObject(forKey: pendingUnregisterOverflowCountKey)
        } else {
            defaults.set(total, forKey: pendingUnregisterOverflowCountKey)
        }
    }

    private static func overflowPageCount(
        accountID: String,
        defaults: UserDefaults
    ) -> Int {
        let stored = defaults.integer(
            forKey: pendingUnregisterOverflowPageCountKey(accountID: accountID)
        )
        if stored > 0 { return stored }
        return defaults.data(
            forKey: pendingUnregisterOverflowPageKey(
                accountID: accountID,
                page: 0
            )
        ) == nil ? 0 : 1
    }

    private static func tokenIndexPageCount(
        tokenHex: String,
        defaults: UserDefaults
    ) -> Int {
        let stored = defaults.integer(
            forKey: pendingUnregisterOverflowTokenIndexPageCountKey(
                tokenHex: tokenHex
            )
        )
        if stored > 0 { return stored }
        return defaults.data(
            forKey: pendingUnregisterOverflowTokenIndexPageKey(
                tokenHex: tokenHex,
                page: 0
            )
        ) == nil ? 0 : 1
    }

    private static func appendTokenIndex(
        tokenHex: String,
        accountID: String,
        defaults: UserDefaults
    ) {
        let pageCount = tokenIndexPageCount(tokenHex: tokenHex, defaults: defaults)
        for page in 0..<max(pageCount, 1) {
            var entries = decodeTokenIndexPage(
                tokenHex: tokenHex,
                page: page,
                defaults: defaults
            )
            if entries.contains(accountID) { return }
            if entries.count < pendingUnregisterOverflowPageSize {
                entries.append(accountID)
                storeTokenIndexPage(
                    entries,
                    tokenHex: tokenHex,
                    page: page,
                    defaults: defaults
                )
                defaults.set(
                    max(pageCount, 1),
                    forKey: pendingUnregisterOverflowTokenIndexPageCountKey(
                        tokenHex: tokenHex
                    )
                )
                return
            }
        }
        storeTokenIndexPage(
            [accountID],
            tokenHex: tokenHex,
            page: max(pageCount, 1),
            defaults: defaults
        )
        defaults.set(
            max(pageCount, 1) + 1,
            forKey: pendingUnregisterOverflowTokenIndexPageCountKey(
                tokenHex: tokenHex
            )
        )
    }

    private static func appendPendingUnregisterOverflow(
        _ entry: PendingUnregister,
        in defaults: UserDefaults
    ) {
        let pageCount = overflowPageCount(
            accountID: entry.accountID,
            defaults: defaults
        )
        for page in 0..<max(pageCount, 1) {
            var entries = decodeOverflowPage(
                accountID: entry.accountID,
                page: page,
                defaults: defaults
            )
            if entries.contains(entry) { return }
            if entries.count < pendingUnregisterOverflowPageSize {
                entries.append(entry)
                storeOverflowPage(
                    entries,
                    accountID: entry.accountID,
                    page: page,
                    defaults: defaults
                )
                defaults.set(
                    max(pageCount, 1),
                    forKey: pendingUnregisterOverflowPageCountKey(
                        accountID: entry.accountID
                    )
                )
                appendTokenIndex(
                    tokenHex: entry.tokenHex,
                    accountID: entry.accountID,
                    defaults: defaults
                )
                incrementOverflowCount(by: 1, defaults: defaults)
                return
            }
        }
        storeOverflowPage(
            [entry],
            accountID: entry.accountID,
            page: max(pageCount, 1),
            defaults: defaults
        )
        defaults.set(
            max(pageCount, 1) + 1,
            forKey: pendingUnregisterOverflowPageCountKey(
                accountID: entry.accountID
            )
        )
        appendTokenIndex(
            tokenHex: entry.tokenHex,
            accountID: entry.accountID,
            defaults: defaults
        )
        incrementOverflowCount(by: 1, defaults: defaults)
    }

    private func appendPendingUnregisterOverflow(_ entry: PendingUnregister) {
        Self.appendPendingUnregisterOverflow(entry, in: defaults)
    }

    private func pendingUnregisterOverflowBatch(
        accountID: String,
        limit: Int
    ) -> [PendingUnregister] {
        guard limit > 0 else { return [] }
        let pageCount = Self.overflowPageCount(
            accountID: accountID,
            defaults: defaults
        )
        var result: [PendingUnregister] = []
        var seen = Set<PendingUnregister>()
        for page in 0..<pageCount {
            for entry in Self.decodeOverflowPage(
                accountID: accountID,
                page: page,
                defaults: defaults
            ) where seen.insert(entry).inserted {
                result.append(entry)
                if result.count == limit { return result }
            }
        }
        return result
    }

    private func removePendingUnregisterOverflow(_ entry: PendingUnregister) {
        removePendingUnregisterOverflow(
            tokenHex: entry.tokenHex,
            accountID: entry.accountID
        )
    }

    private func removePendingUnregisterOverflow(
        tokenHex: String,
        accountID: String
    ) {
        let pageCount = Self.overflowPageCount(
            accountID: accountID,
            defaults: defaults
        )
        for page in 0..<pageCount {
            var entries = Self.decodeOverflowPage(
                accountID: accountID,
                page: page,
                defaults: defaults
            )
            let oldCount = entries.count
            entries.removeAll {
                $0.tokenHex == tokenHex && $0.accountID == accountID
            }
            guard entries.count != oldCount else { continue }
            Self.storeOverflowPage(
                entries,
                accountID: accountID,
                page: page,
                defaults: defaults
            )
            var remainingPages = pageCount
            while remainingPages > 0,
                  Self.decodeOverflowPage(
                      accountID: accountID,
                      page: remainingPages - 1,
                      defaults: defaults
                  ).isEmpty {
                defaults.removeObject(
                    forKey: pendingUnregisterOverflowPageKey(
                        accountID: accountID,
                        page: remainingPages - 1
                    )
                )
                remainingPages -= 1
            }
            if remainingPages == 0 {
                defaults.removeObject(
                    forKey: pendingUnregisterOverflowPageCountKey(
                        accountID: accountID
                    )
                )
            } else {
                defaults.set(
                    remainingPages,
                    forKey: pendingUnregisterOverflowPageCountKey(
                        accountID: accountID
                    )
                )
            }
            if !overflowContains(
                tokenHex: tokenHex,
                accountID: accountID
            ) {
                removeTokenIndex(tokenHex: tokenHex, accountID: accountID)
            }
            Self.incrementOverflowCount(by: -1, defaults: defaults)
            return
        }
        // The index and page are separate UserDefaults writes. If a process
        // dies between them, discard the stale index reference so cleanup
        // remains finite and the next registration cannot spin forever.
        removeTokenIndex(tokenHex: tokenHex, accountID: accountID)
    }

    private func overflowContains(
        tokenHex: String,
        accountID: String
    ) -> Bool {
        let pageCount = Self.overflowPageCount(
            accountID: accountID,
            defaults: defaults
        )
        for page in 0..<pageCount where Self.decodeOverflowPage(
            accountID: accountID,
            page: page,
            defaults: defaults
        ).contains(where: { $0.tokenHex == tokenHex }) {
            return true
        }
        return false
    }

    private func removeTokenIndex(tokenHex: String, accountID: String) {
        let pageCount = Self.tokenIndexPageCount(
            tokenHex: tokenHex,
            defaults: defaults
        )
        for page in 0..<pageCount {
            var entries = Self.decodeTokenIndexPage(
                tokenHex: tokenHex,
                page: page,
                defaults: defaults
            )
            let oldCount = entries.count
            entries.removeAll { $0 == accountID }
            guard entries.count != oldCount else { continue }
            Self.storeTokenIndexPage(
                entries,
                tokenHex: tokenHex,
                page: page,
                defaults: defaults
            )
            var remainingPages = pageCount
            while remainingPages > 0,
                  Self.decodeTokenIndexPage(
                      tokenHex: tokenHex,
                      page: remainingPages - 1,
                      defaults: defaults
                  ).isEmpty {
                defaults.removeObject(
                    forKey: pendingUnregisterOverflowTokenIndexPageKey(
                        tokenHex: tokenHex,
                        page: remainingPages - 1
                    )
                )
                remainingPages -= 1
            }
            if remainingPages == 0 {
                defaults.removeObject(
                    forKey: pendingUnregisterOverflowTokenIndexPageCountKey(
                        tokenHex: tokenHex
                    )
                )
            } else {
                defaults.set(
                    remainingPages,
                    forKey: pendingUnregisterOverflowTokenIndexPageCountKey(
                        tokenHex: tokenHex
                    )
                )
            }
            return
        }
    }

    private func firstOverflowAccount(for tokenHex: String) -> String? {
        let pageCount = Self.tokenIndexPageCount(
            tokenHex: tokenHex,
            defaults: defaults
        )
        for page in 0..<pageCount {
            if let accountID = Self.decodeTokenIndexPage(
                tokenHex: tokenHex,
                page: page,
                defaults: defaults
            ).first {
                return accountID
            }
        }
        return nil
    }

    private func clearPendingUnregisterToken(tokenHex: String) {
        storePendingUnregisters(
            pendingUnregisters.filter { $0.tokenHex != tokenHex }
        )
        while let accountID = firstOverflowAccount(for: tokenHex) {
            removePendingUnregisterOverflow(
                tokenHex: tokenHex,
                accountID: accountID
            )
        }
    }

    private func clearRegisteredOwner(
        accountID: String,
        tokenHex: String
    ) {
        guard cachedTokenHex == tokenHex,
              defaults.string(
                  forKey: Self.registeredAccountIDKey
              ) == accountID else {
            return
        }
        defaults.removeObject(forKey: Self.registeredAccountIDKey)
    }

    public func deviceTokenRegistrationFailed() {
        cancelRetry()
        guard isEnabled else {
            publish(.disabled)
            return
        }
        publish(PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: cachedTokenHex != nil,
            backendState: .deviceTokenRegistrationFailed
        ))
    }

    private func cancelRetry(invalidateOperation: Bool = true) {
        if invalidateOperation {
            operationGeneration = UUID()
        }
        retryTask?.cancel()
        retryTask = nil
    }

    private func publish(_ snapshot: PushRegistrationSnapshot) {
        guard snapshotValue != snapshot else { return }
        snapshotValue = snapshot
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private static func failureResult(
        statusCode: Int,
        response: HTTPURLResponse,
        data: Data
    ) -> RegistrationResult {
        switch statusCode {
        case 300...399:
            return .failure(.invalidServerResponse, retryAfter: nil)
        case 408, 425:
            let seconds = retryAfterSeconds(response: response, body: data)
            return .failure(
                .serviceUnavailable,
                retryAfter: seconds.map(Duration.seconds)
            )
        case 401:
            return .failure(.authenticationRequired, retryAfter: nil)
        case 409:
            let body = try? JSONDecoder().decode(
                RegistrationErrorResponse.self,
                from: data
            )
            if body?.error == "push_delivery_in_progress" {
                let seconds = retryAfterSeconds(
                    response: response,
                    body: data
                )
                return .failure(
                    .serviceUnavailable,
                    retryAfter: seconds.map(Duration.seconds)
                )
            }
            return .failure(.accountDeletionInProgress, retryAfter: nil)
        case 429:
            let body = try? JSONDecoder().decode(
                RegistrationErrorResponse.self,
                from: data
            )
            if body?.error == "too_many_devices" {
                return .failure(
                    .deviceLimitReached(limit: max(1, body?.limit ?? 200)),
                    retryAfter: nil
                )
            }
            let seconds = retryAfterSeconds(
                response: response,
                body: data
            )
            return .failure(
                .rateLimited(retryAfterSeconds: seconds),
                retryAfter: seconds.map(Duration.seconds)
            )
        case 500...599:
            return .failure(.serviceUnavailable, retryAfter: nil)
        default:
            return .failure(.rejected(statusCode: statusCode), retryAfter: nil)
        }
    }

    private static func retryAfterSeconds(
        response: HTTPURLResponse,
        body: Data
    ) -> Int? {
        let headerDelay = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Int.init)
        let bodyDelay = try? JSONDecoder().decode(
            RegistrationErrorResponse.self,
            from: body
        ).retryAfterSeconds
        guard let raw = headerDelay ?? bodyDelay else { return nil }
        return min(max(raw, 0), 600)
    }

    private static func jittered(_ duration: Duration, multiplier: Double) -> Duration {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let nanoseconds = seconds * multiplier * 1_000_000_000
        guard nanoseconds.isFinite else {
            return .nanoseconds(nanoseconds.sign == .minus
                ? Int64.min
                : Int64.max)
        }
        if nanoseconds >= Double(Int64.max) {
            return .nanoseconds(Int64.max)
        }
        if nanoseconds <= Double(Int64.min) {
            return .nanoseconds(Int64.min)
        }
        return .nanoseconds(Int64(nanoseconds))
    }
}

private enum RegistrationResult {
    case success(pushServiceConfigured: Bool)
    case failure(PushRegistrationFailure, retryAfter: Duration?)
}

private struct PushRequest {
    let request: URLRequest
    let session: AuthenticatedSessionSnapshot?
}

private struct RegistrationAcknowledgement: Decodable {
    let ok: Bool
    let pushServiceConfigured: Bool?
}

private struct RegistrationErrorResponse: Decodable {
    let error: String?
    let retryAfterSeconds: Int?
    let limit: Int?
}

private struct PendingUnregister: Codable, Hashable {
    let tokenHex: String
    let accountID: String
}
