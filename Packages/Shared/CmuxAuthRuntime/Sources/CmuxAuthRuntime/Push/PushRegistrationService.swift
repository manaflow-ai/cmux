public import Foundation
import OSLog

private let pushLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

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
    private let pendingUnregisterStoreURL: URL
    private var pendingUnregisterStore: PendingUnregisterStore?
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
    private var coordinatorIntentReconciledGeneration: UInt64?
    private var pendingUnregisterRecoveryTask: Task<Void, Never>?
    private var pendingUnregisterRecoveryGeneration: UUID?
    private var unregisterDrainPreferenceGeneration: UUID?

    // Actor reentrancy lets a second lifecycle callback enter while the first
    // POST is suspended in URLSession. Keep one in-flight upload per token so
    // foreground refresh, auth revalidation, and APNs callbacks cannot create
    // duplicate writes. A different token, or a deliberately superseding
    // operation after stale-session reconciliation, gets its own generation.
    private var uploadTask: Task<Void, Never>?
    private var uploadTaskTokenHex: String?
    private var uploadTaskGeneration: UUID?
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
    private static let pendingUnregisterAttemptBudget = 4

    private static func defaultPendingUnregisterStoreURL(
        suiteName: String?,
        bundleID: String
    ) -> URL {
        let namespace = (suiteName ?? bundleID).map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        }
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(
                "push-cleanup-\(String(namespace)).sqlite3"
            )
    }

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
        pendingUnregisterStoreURL: URL? = nil,
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
        let storeURL = pendingUnregisterStoreURL
            ?? Self.defaultPendingUnregisterStoreURL(
                suiteName: suiteName,
                bundleID: bundleID
            )
        self.pendingUnregisterStoreURL = storeURL
        do {
            self.pendingUnregisterStore = try PendingUnregisterStore(
                databaseURL: storeURL
            )
        } catch {
            self.pendingUnregisterStore = nil
            pushLog.error("Unable to open durable push-token cleanup store")
        }
        Self.migrateLegacyPendingUnregisters(
            in: self.defaults,
            overflowStore: self.pendingUnregisterStore
        )
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
           hasPendingUnregisters || hasKnownRegistration {
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
        operationGeneration = UUID()
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
    /// app-owned backend cleanup and awaits its bounded attempt; enable waits
    /// for the coordinator's separate post-authorization reconciliation call.
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
        coordinatorIntentReconciledGeneration = nil
        operationGeneration = UUID()
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
            // The worker is app-owned, so cancellation of a stale Settings
            // task cannot cancel privacy cleanup. Awaiting it preserves the
            // public `disable()` completion guarantee for callers that clear
            // authentication immediately afterwards.
            await disableIntentReconciliationTask?.value
        }
    }

    /// Reconciles an enabled intent only after iOS authorization has succeeded.
    /// Stale generations cannot upload a cached APNs token.
    public func reconcileEnabledIntent(generation: UInt64) async {
        guard generation == coordinatorIntentGeneration,
              coordinatorIntentEnabled == true,
              isEnabled else { return }
        coordinatorIntentReconciledGeneration = generation
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
        guard canUploadForCurrentIntent else {
            publish(
                isEnabled
                    ? PushRegistrationSnapshot(
                        isEnabled: true,
                        hasDeviceToken: true,
                        backendState: .registrationRequired
                    )
                    : .disabled
            )
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
        guard canUploadForCurrentIntent else {
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: cachedTokenHex != nil,
                backendState: cachedTokenHex == nil
                    ? .awaitingDeviceToken
                    : .registrationRequired
            ))
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
        // Treat direct cleanup retries as the current opt-out operation too,
        // so a newer enable can supersede an in-flight DELETE and trigger the
        // same final re-upload repair as coordinator-owned cleanup.
        cancelRetry()
        await unregisterFromServer(
            preferenceGeneration: operationGeneration,
            requiresDisabledPreference: false
        )
    }

    private func unregisterFromServer(
        preferenceGeneration: UUID?,
        requiresDisabledPreference: Bool = true
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
            phase: .pushUnregistrationSession,
            recoveryGeneration: preferenceGeneration
        )
        if let preferenceGeneration,
           preferenceGeneration != operationGeneration
               || (requiresDisabledPreference && isEnabled) {
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
            let preferenceWasSuperseded = preferenceGeneration.map {
                $0 != operationGeneration
                    || (requiresDisabledPreference && isEnabled)
            } ?? false
            if preferenceWasSuperseded,
               enableIntentIsReconciled,
               let currentToken = cachedTokenHex,
               currentToken == hex {
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
        while canUploadForCurrentIntent, cachedTokenHex == tokenHex {
            if let inFlightTask = uploadTask,
               uploadTaskGeneration != replacingGeneration {
                let inFlightGeneration = uploadTaskGeneration
                await inFlightTask.value
                if uploadTaskGeneration == inFlightGeneration {
                    uploadTask = nil
                    uploadTaskTokenHex = nil
                    uploadTaskGeneration = nil
                }
                guard canUploadForCurrentIntent,
                      cachedTokenHex == tokenHex else { return }
                if snapshotValue.backendState == .registered {
                    return
                }
                // The mutation already represented the current operation. A
                // newer generation loops and starts only after it completes.
                if inFlightGeneration == operationGeneration {
                    return
                }
                continue
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
            await task.value
            if uploadTaskGeneration == generation {
                uploadTask = nil
                uploadTaskTokenHex = nil
                uploadTaskGeneration = nil
            }
            return
        }
    }

    private func attemptUpload(
        tokenHex: String,
        generation: UUID,
        remainingDelays: [Duration]
    ) async {
        guard canUploadForCurrentIntent,
              generation == operationGeneration,
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
            // A POST can commit before its response reaches the app. Record
            // the owner first so a crash followed by an opt-out relaunch still
            // has enough identity to delete that ambiguous registration.
            if let requestSession = context.session {
                persistPendingUnregister(
                    tokenHex: tokenHex,
                    accountID: requestSession.accountID
                )
            }
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
            if previousOwnerID != nil || hasPendingUnregisters {
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
            body: [
                "deviceToken": tokenHex,
                "bundleId": bundleID,
            ],
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
        request.setValue(bundleID, forHTTPHeaderField: "X-Cmux-App-Namespace")
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
            phase: .pushUnregistrationSession,
            recoveryGeneration: preferenceGeneration
        ) else { return }
        if let preferenceGeneration,
           preferenceGeneration != operationGeneration || isEnabled {
            return
        }
        let currentAccountID = session.accountID
        var seen = Set<PendingUnregister>()
        let matching = (
                pendingUnregisterOverflowBatch(
                    accountID: currentAccountID,
                    // Keep one lookahead entry so a bounded batch can tell
                    // whether another continuation is required.
                    limit: Self.pendingUnregisterAttemptBudget + 1
                ) + pendingUnregisterFallbackBatch(
                    accountID: currentAccountID,
                    limit: Self.pendingUnregisterAttemptBudget + 1
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
           enableIntentIsReconciled,
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
            schedulePendingUnregisterContinuation(
                preferenceGeneration: preferenceGeneration
            )
        }
    }

    private func boundedSessionSnapshot(
        phase: AuthPhase,
        recoveryGeneration: UUID? = nil
    ) async -> AuthenticatedSessionSnapshot? {
        let tokenProvider = tokenProvider
        do {
            return try await withAuthPhaseTimeout(
                phase,
                duration: sessionSnapshotTimeout,
                clock: sessionSnapshotClock,
                log: authLog,
                registry: sessionSnapshotTimeoutRegistry,
                blocksRetriesWhileTimedOutOperationActive: true
            ) {
                // This provider API only reads a coherent stored token pair or
                // awaits bounded launch bootstrap. Cancelling it cannot leave
                // an ambiguous server mutation behind.
                try await tokenProvider.authenticatedSessionSnapshot()
            }
        } catch let error as AuthError where error == .timedOut {
            schedulePendingUnregisterRecovery(
                preferenceGeneration: recoveryGeneration
            )
            return nil
        } catch {
            return nil
        }
    }

    private var enableIntentIsReconciled: Bool {
        guard isEnabled else { return false }
        if coordinatorIntentEnabled == true {
            return coordinatorIntentReconciledGeneration
                == coordinatorIntentGeneration
        }
        return coordinatorIntentEnabled == nil
    }

    private var canUploadForCurrentIntent: Bool {
        enableIntentIsReconciled
    }

    private func persistPendingUnregister(tokenHex: String, accountID: String) {
        let entry = PendingUnregister(tokenHex: tokenHex, accountID: accountID)
        if durablePendingUnregisterStore()?.insert(entry) == true {
            // SQLite is durable before the legacy fallback is removed.
            storePendingUnregisters(
                pendingUnregisters.filter { $0 != entry }
            )
            return
        }
        var queue = pendingUnregisters
        queue.removeAll { $0 == entry }
        queue.append(entry)
        storePendingUnregisters(queue)
    }

    private func schedulePendingUnregisterContinuation(
        preferenceGeneration: UUID? = nil
    ) {
        if let preferenceGeneration {
            unregisterDrainPreferenceGeneration = preferenceGeneration
        }
        guard unregisterDrainTask == nil else { return }
        unregisterDrainTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.runPendingUnregisterContinuation()
        }
    }

    private func schedulePendingUnregisterRecovery(
        preferenceGeneration: UUID?
    ) {
        if let preferenceGeneration {
            pendingUnregisterRecoveryGeneration = preferenceGeneration
        }
        guard pendingUnregisterRecoveryTask == nil else { return }
        let clock = sessionSnapshotClock
        pendingUnregisterRecoveryTask = Task { [weak self, clock] in
            do {
                // AuthPhaseTimeoutRegistry holds a timed-out phase for 30s.
                // Wait past that lease before asking the worker to retry.
                try await clock.sleep(for: .seconds(31))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.finishPendingUnregisterRecovery()
        }
    }

    private func finishPendingUnregisterRecovery() {
        pendingUnregisterRecoveryTask = nil
        let generation = pendingUnregisterRecoveryGeneration
        pendingUnregisterRecoveryGeneration = nil
        guard hasPendingUnregisters else { return }
        schedulePendingUnregisterContinuation(
            preferenceGeneration: generation
        )
    }

    private func runPendingUnregisterContinuation() async {
        unregisterDrainTask = nil
        let generation = unregisterDrainPreferenceGeneration
        unregisterDrainPreferenceGeneration = nil
        await retryPendingUnregisterIfPossible(
            preferenceGeneration: generation
        )
    }

    private func clearPendingUnregister(
        tokenHex: String,
        accountID: String
    ) {
        _ = durablePendingUnregisterStore()?.remove(
            tokenHex: tokenHex,
            accountID: accountID
        )
        storePendingUnregisters(pendingUnregisters.filter { entry in
            entry.tokenHex != tokenHex || entry.accountID != accountID
        })
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
        in defaults: UserDefaults,
        overflowStore: PendingUnregisterStore?
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
        guard normalized.isEmpty
                || overflowStore?.insertAll(normalized) == true else {
            // Keep every legacy key intact when durable migration fails.
            return
        }
        defaults.removeObject(forKey: pendingUnregisterQueueKey)
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
        if normalized.isEmpty {
            defaults.removeObject(forKey: Self.pendingUnregisterQueueKey)
            defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
            defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Self.pendingUnregisterQueueKey)
        }
        defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
        defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
    }

    private var hasPendingUnregisters: Bool {
        durablePendingUnregisterStore()?.hasEntries == true
            || !pendingUnregisters.isEmpty
    }

    private func pendingUnregisterOverflowBatch(
        accountID: String,
        limit: Int
    ) -> [PendingUnregister] {
        durablePendingUnregisterStore()?.batch(
            accountID: accountID,
            limit: limit
        ) ?? []
    }

    private func pendingUnregisterFallbackBatch(
        accountID: String,
        limit: Int
    ) -> [PendingUnregister] {
        Array(pendingUnregisters.lazy.filter {
            $0.accountID == accountID
        }.prefix(limit))
    }

    private func clearPendingUnregisterToken(tokenHex: String) {
        _ = durablePendingUnregisterStore()?.removeAll(tokenHex: tokenHex)
        storePendingUnregisters(
            pendingUnregisters.filter { $0.tokenHex != tokenHex }
        )
    }

    private func durablePendingUnregisterStore() -> PendingUnregisterStore? {
        if let pendingUnregisterStore {
            return pendingUnregisterStore
        }
        do {
            let store = try PendingUnregisterStore(
                databaseURL: pendingUnregisterStoreURL
            )
            pendingUnregisterStore = store
            Self.migrateLegacyPendingUnregisters(
                in: defaults,
                overflowStore: store
            )
            pushLog.info("Recovered durable push-token cleanup store")
            return store
        } catch {
            pushLog.error("Unable to recover durable push-token cleanup store")
            return nil
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
