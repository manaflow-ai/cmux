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
    private let session: URLSession
    private let retryDelays: [Duration]
    private let retryJitter: @Sendable (ClosedRange<Double>) -> Double
    private let retrySleep: @Sendable (Duration) async throws -> Void
    /// Direct sign-out cleanup overloads share captured credentials and remain
    /// serialized independently from preference reconciliation.
    private let unregisterIntentGate = PushRegistrationMutationGate()
    /// The actor itself is re-entrant across URLSession suspension points.
    /// Serialize actual POST/DELETE requests so a late response cannot race a
    /// newer request. Higher-level reconciliation remains concurrent so account
    /// changes can still observe and repair stale acknowledgements.
    private let networkMutationGate = PushRegistrationMutationGate()
    private var retryTask: Task<Void, Never>?
    private var unregisterDrainTask: Task<Void, Never>?
    private var operationGeneration = UUID()
    /// Orders registration and direct sign-out mutations before either path
    /// can suspend while preparing credentials or waiting for the network gate.
    private var serverMutationGeneration: UInt64 = 0
    /// Every preference mutation, including the legacy public mutation APIs,
    /// is assigned one service-owned generation and enters this queue. A
    /// direct mutation therefore advances the same ordering domain as a
    /// coordinator intent and replaces any coordinator work still pending.
    private var preferenceIntentGeneration: UInt64 = 0
    private var coordinatorGeneration: UInt64?
    /// Direct callers invalidate all coordinator generations already admitted.
    /// This is validation metadata only; mutation ordering uses
    /// `preferenceIntentGeneration` above.
    private var coordinatorGenerationInvalidatedThrough: UInt64?
    private var latestCoordinatorIntent: PushRegistrationIntent?
    private var committedPreferenceIntent: PushRegistrationIntent?
    private var preferenceIntentQueue: PushRegistrationIntentQueue?
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
        }
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
        persistDisabledPushRegistrationCleanupIfNeeded(
            in: self.defaults,
            enabledKey: Self.enabledKey,
            cachedTokenKey: Self.cachedTokenKey,
            registeredAccountIDKey: Self.registeredAccountIDKey,
            pendingUnregisterQueueKey: Self.pendingUnregisterQueueKey
        )
        self.session = session
        self.retryDelays = retryDelays
        self.retryJitter = retryJitter
        self.retrySleep = retrySleep
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

    /// Whether the persisted user preference permits push registration.
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The latest local token and backend-registration state.
    public var snapshot: PushRegistrationSnapshot { snapshotValue }

    /// Streams the current snapshot followed by every meaningful state change.
    public func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        let id = UUID()
        if !isEnabled, !pendingUnregisters.isEmpty {
            schedulePendingUnregisterContinuation(
                preferenceGeneration: preferenceIntentGeneration
            )
        }
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(snapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    /// Persists a preference and reconciles its token registration in order.
    public func setEnabled(_ enabled: Bool) async {
        invalidateCoordinatorIntents()
        await submitPreferenceIntent(enabled: enabled)
    }

    /// Disables local delivery and removes the owned token from the server.
    ///
    /// The caller may persist the user's opt-out before invoking this method;
    /// cleanup therefore uses the persisted registration owner rather than the
    /// now-false preference to decide whether a delete is required.
    public func disableAndUnregister() async {
        invalidateCoordinatorIntents()
        await submitPreferenceIntent(enabled: false)
    }

    /// Applies an authoritative intent without an external coordinator epoch.
    /// Test and direct in-module callers use this convenience entrypoint.
    func applyEnabledIntent(
        _ enabled: Bool,
        generation: UInt64
    ) async {
        let intentEpoch = advancePreferenceIntentEpoch()
        await applyEnabledIntent(
            enabled,
            generation: generation,
            intentEpoch: intentEpoch
        )
    }

    /// Applies the newest coordinator-owned preference when its creation epoch
    /// is still current, replacing stale queued work and sharing duplicates.
    public func applyEnabledIntent(
        _ enabled: Bool,
        generation: UInt64,
        intentEpoch: PushRegistrationIntentEpoch
    ) async {
        guard isCurrentPreferenceIntentEpoch(intentEpoch) else { return }
        if let invalidatedThrough = coordinatorGenerationInvalidatedThrough,
           generation <= invalidatedThrough
        {
            return
        }
        if let currentGeneration = coordinatorGeneration {
            guard generation >= currentGeneration else { return }
            if generation == currentGeneration {
                guard let latestCoordinatorIntent else { return }
                await submitPreferenceIntent(latestCoordinatorIntent)
                return
            }
        }
        coordinatorGeneration = generation
        let intent = makePreferenceIntent(enabled: enabled)
        latestCoordinatorIntent = intent
        await submitPreferenceIntent(intent)
    }

    private func submitPreferenceIntent(enabled: Bool) async {
        await submitPreferenceIntent(makePreferenceIntent(enabled: enabled))
    }

    private func submitPreferenceIntent(
        _ intent: PushRegistrationIntent
    ) async {
        commitPreferenceIntent(intent)
        if preferenceIntentQueue == nil {
            preferenceIntentQueue = PushRegistrationIntentQueue { [weak self] intent in
                await self?.reconcilePreferenceIntent(intent)
            }
        }
        await preferenceIntentQueue!.submit(intent)
    }

    private func makePreferenceIntent(enabled: Bool) -> PushRegistrationIntent {
        preferenceIntentGeneration &+= 1
        return PushRegistrationIntent(
            enabled: enabled,
            generation: preferenceIntentGeneration
        )
    }

    private func invalidateCoordinatorIntents() {
        _ = advancePreferenceIntentEpoch()
        coordinatorGenerationInvalidatedThrough = coordinatorGeneration
        latestCoordinatorIntent = nil
    }

    private func advancePreferenceIntentEpoch() -> PushRegistrationIntentEpoch {
        let intentEpoch = PushRegistrationIntentEpoch()
        defaults.set(
            intentEpoch.storageValue,
            forKey: PushRegistrationIntentEpoch.defaultsKey
        )
        return intentEpoch
    }

    private func isCurrentPreferenceIntentEpoch(
        _ intentEpoch: PushRegistrationIntentEpoch
    ) -> Bool {
        defaults.string(forKey: PushRegistrationIntentEpoch.defaultsKey)
            == intentEpoch.storageValue
    }

    /// Commits the latest user preference before any authentication or network
    /// suspension. Same-direction reconciliation can remain bounded behind an
    /// older preparation without delaying the durable toggle state.
    private func commitPreferenceIntent(_ intent: PushRegistrationIntent) {
        guard isCurrentPreferenceIntent(intent.generation),
              committedPreferenceIntent != intent else {
            return
        }
        committedPreferenceIntent = intent
        cancelRetry()
        if !intent.enabled {
            persistCapturedUnregisterObligation(accountID: nil)
        }
        defaults.set(intent.enabled, forKey: Self.enabledKey)
        if intent.enabled {
            let hasToken = cachedTokenHex != nil
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: hasToken,
                backendState: hasToken
                    ? .registrationRequired
                    : .awaitingDeviceToken
            ))
        } else {
            publish(.disabled)
        }
    }

    private func reconcilePreferenceIntent(
        _ intent: PushRegistrationIntent
    ) async {
        guard isCurrentPreferenceIntent(intent.generation) else {
            return
        }
        if intent.enabled {
            await syncTokenIfPossibleUnlocked()
        } else {
            await unregisterFromServerUnlocked(
                preferenceGeneration: intent.generation
            )
            await retryPendingUnregisterIfPossible(
                preferenceGeneration: intent.generation
            )
            guard isCurrentOptOut(intent.generation) else { return }
            publish(.disabled)
        }
    }

    private func isCurrentPreferenceIntent(_ generation: UInt64) -> Bool {
        preferenceIntentGeneration == generation
    }

    /// Caches an APNs device token and uploads it when push is enabled.
    public func register(deviceToken: Data) async {
        await registerUnlocked(deviceToken: deviceToken)
    }

    private func registerUnlocked(deviceToken: Data) async {
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
        cancelRetry()
        await upload(tokenHex: hex)
        if snapshotValue.backendState == .registered {
            await retryPendingUnregisterIfPossible()
        }
    }

    /// Reconciles cached registration and pending cleanup with the current account.
    public func syncTokenIfPossible() async {
        await syncTokenIfPossibleUnlocked()
    }

    private func syncTokenIfPossibleUnlocked() async {
        let preferenceGeneration = preferenceIntentGeneration
        guard isEnabled else {
            await retryPendingUnregisterIfPossible(
                preferenceGeneration: preferenceGeneration
            )
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
        cancelRetry()
        await upload(tokenHex: hex)
        // Current-account registration is the readiness-critical operation.
        // Historical cleanup follows it, with its own bounded attempt budget.
        if snapshotValue.backendState == .registered {
            await retryPendingUnregisterIfPossible()
        }
    }

    /// Durably schedules and attempts removal of the currently owned token.
    public func unregisterFromServer() async {
        let serverMutationGeneration = beginServerMutation()
        persistCapturedUnregisterObligation(accountID: nil)
        await unregisterIntentGate.withLock { [self] in
            await self.unregisterFromServerUnlocked(
                serverMutationGeneration: serverMutationGeneration
            )
        }
    }

    private func unregisterFromServerUnlocked(
        preferenceGeneration: UInt64? = nil,
        serverMutationGeneration: UInt64? = nil
    ) async {
        cancelRetry()
        guard let hex = cachedTokenHex else { return }
        // A live session identifies who is signed in now, not who owns this
        // token. During an account switch those can differ, so fail closed
        // unless the registration owner is persisted in either the owner
        // marker or a durable cleanup obligation.
        guard let ownerID = persistedOwnerID(for: hex) else {
            pushLog.info("Skipping push-token unregister: persisted owner unavailable")
            return
        }
        // Persist before requiring live auth. This is the privacy guarantee for
        // an offline or signed-out opt-out.
        persistPendingUnregister(tokenHex: hex, accountID: ownerID)
        let session = try? await tokenProvider.authenticatedSessionSnapshot()
        // A token acknowledged for account A must never be deleted using
        // account B credentials. Its tombstone waits for A to return.
        guard let session, session.accountID == ownerID else { return }
        if await sendDelete(
            tokenHex: hex,
            sessionSnapshot: session,
            preferenceGeneration: preferenceGeneration,
            serverMutationGeneration: serverMutationGeneration
        ) {
            clearPendingUnregister(tokenHex: hex, accountID: ownerID)
            clearRegisteredOwner(accountID: ownerID, tokenHex: hex)
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
        let serverMutationGeneration = beginServerMutation()
        persistCapturedUnregisterObligation(accountID: nil)
        await unregisterIntentGate.withLock { [self] in
            await self.unregisterFromServerUnlocked(
                accountID: nil,
                accessToken: accessToken,
                refreshToken: refreshToken,
                serverMutationGeneration: serverMutationGeneration
            )
        }
    }

    /// Sign-out variant with the account id captured before local auth clear.
    public func unregisterFromServer(
        accountID capturedAccountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {
        let serverMutationGeneration = beginServerMutation()
        persistCapturedUnregisterObligation(accountID: capturedAccountID)
        await unregisterIntentGate.withLock { [self] in
            await self.unregisterFromServerUnlocked(
                accountID: capturedAccountID,
                accessToken: accessToken,
                refreshToken: refreshToken,
                serverMutationGeneration: serverMutationGeneration
            )
        }
    }

    /// Records the cleanup obligation before waiting on the mutation gate.
    /// Sign-out callers are commonly canceled while an earlier registration is
    /// still in flight; the durable tombstone must not depend on admission to
    /// that cancellable queue.
    private func persistCapturedUnregisterObligation(accountID: String?) {
        guard let hex = cachedTokenHex else { return }
        let ownerID = persistedOwnerID(for: hex) ?? accountID
        guard let ownerID, !ownerID.isEmpty else { return }
        persistPendingUnregister(tokenHex: hex, accountID: ownerID)
    }

    private func unregisterFromServerUnlocked(
        accountID capturedAccountID: String?,
        accessToken: String?,
        refreshToken: String?,
        serverMutationGeneration: UInt64
    ) async {
        cancelRetry()
        guard let hex = cachedTokenHex else { return }
        let persistedOwner = persistedOwnerID(for: hex)
        let ownerID = persistedOwner ?? capturedAccountID
        if let ownerID, !ownerID.isEmpty {
            // Persist the recovery record before validating credentials.
            // Offline sign-out commonly has only the refresh token, but a
            // later sign-in to this same account can safely finish the DELETE.
            persistPendingUnregister(tokenHex: hex, accountID: ownerID)
        }
        if let persistedOwner,
           capturedAccountID != persistedOwner {
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
            capturedRefreshToken: refreshToken,
            serverMutationGeneration: serverMutationGeneration
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

    private func upload(tokenHex: String) async {
        operationGeneration = UUID()
        let generation = operationGeneration
        let serverMutationGeneration = beginServerMutation()
        await attemptUpload(
            tokenHex: tokenHex,
            generation: generation,
            serverMutationGeneration: serverMutationGeneration,
            remainingDelays: retryDelays
        )
    }

    private func attemptUpload(
        tokenHex: String,
        generation: UUID,
        serverMutationGeneration: UInt64,
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
            ]
        )
        let result: RegistrationResult
        let requestSession: AuthenticatedSessionSnapshot?
        switch request {
        case let .success(context):
            requestSession = context.session
            result = await performRegistration(
                context.request,
                tokenHex: tokenHex,
                generation: generation,
                serverMutationGeneration: serverMutationGeneration,
                cleanupAccountID: requestSession?.accountID
            )
        case let .failure(failure):
            requestSession = nil
            result = .failure(failure, retryAfter: nil)
        }
        let operationIsCurrent = isEnabled
            && generation == operationGeneration
            && serverMutationGeneration == self.serverMutationGeneration
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
                staleSession: requestSession
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
        case .cancelled:
            // The gate may reject a cancelled waiter before any request starts.
            // Leave the enabled token recoverable instead of stranding the
            // snapshot in `.registering` with no future reconciliation.
            publish(PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .registrationRequired
            ))
            scheduleUploadRetry(
                failure: .networkUnavailable,
                retryAfter: nil,
                tokenHex: tokenHex,
                generation: generation,
                serverMutationGeneration: serverMutationGeneration,
                remainingDelays: remainingDelays
            )
            return
        case let .success(pushServiceConfigured):
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
            for pending in pendingUnregisters where pending.tokenHex == tokenHex {
                clearPendingUnregister(
                    tokenHex: pending.tokenHex,
                    accountID: pending.accountID
                )
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
                    serverMutationGeneration: serverMutationGeneration,
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
                serverMutationGeneration: serverMutationGeneration,
                remainingDelays: remainingDelays
            )
        }
    }

    private func scheduleUploadRetry(
        failure: PushRegistrationFailure,
        retryAfter: Duration?,
        tokenHex: String,
        generation: UUID,
        serverMutationGeneration: UInt64,
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
                serverMutationGeneration: serverMutationGeneration,
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
        staleSession: AuthenticatedSessionSnapshot
    ) async {
        let currentSession = try? await tokenProvider
            .authenticatedSessionSnapshot()
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
              let currentSession = try? await tokenProvider
                  .authenticatedSessionSnapshot(),
              await tokenProvider.isAuthenticatedSessionCurrent(currentSession)
        else { return }
        await upload(tokenHex: currentToken)
    }

    private func sendDelete(
        tokenHex: String,
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil,
        sessionSnapshot: AuthenticatedSessionSnapshot? = nil,
        preferenceGeneration: UInt64? = nil,
        serverMutationGeneration: UInt64? = nil
    ) async -> Bool {
        guard case let .success(context) = await makeRequest(
            method: "DELETE",
            path: "/api/device-tokens",
            body: ["deviceToken": tokenHex],
            capturedAccessToken: capturedAccessToken,
            capturedRefreshToken: capturedRefreshToken,
            sessionSnapshot: sessionSnapshot
        ) else { return false }
        guard await performDelete(
            context.request,
            preferenceGeneration: preferenceGeneration,
            serverMutationGeneration: serverMutationGeneration
        ) else { return false }
        if let preferenceGeneration,
           !isCurrentOptOut(preferenceGeneration) {
            return false
        }
        if let serverMutationGeneration,
           serverMutationGeneration != self.serverMutationGeneration {
            return false
        }
        if let session = context.session {
            guard await tokenProvider.isAuthenticatedSessionCurrent(session)
            else { return false }
            if let preferenceGeneration {
                return isCurrentOptOut(preferenceGeneration)
            }
        }
        return true
    }

    private func makeRequest(
        method: String,
        path: String,
        body: [String: String],
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil,
        sessionSnapshot: AuthenticatedSessionSnapshot? = nil
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
            do {
                let session = try await tokenProvider
                    .authenticatedSessionSnapshot()
                accessToken = session.accessToken
                refreshToken = session.refreshToken
                authenticatedSession = session
            } catch {
                return .failure(.authenticationRequired)
            }
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

    private func performRegistration(
        _ request: URLRequest,
        tokenHex: String,
        generation: UUID,
        serverMutationGeneration: UInt64,
        cleanupAccountID: String?
    ) async -> RegistrationResult {
        await networkMutationGate.withLock { [self] in
            guard await self.isCurrentUpload(
                tokenHex: tokenHex,
                generation: generation,
                serverMutationGeneration: serverMutationGeneration
            ) else {
                return .cancelled
            }
            // The POST may commit even if this process is suspended before its
            // response arrives. Persist its cleanup owner only after the gate
            // admits this still-current request, so a quarantined stale worker
            // cannot recreate a tombstone after a newer POST has succeeded.
            if let cleanupAccountID {
                await self.persistPendingUnregister(
                    tokenHex: tokenHex,
                    accountID: cleanupAccountID
                )
            }
            return await self.performRegistrationRequest(request)
        } ?? .cancelled
    }

    private func isCurrentUpload(
        tokenHex: String,
        generation: UUID,
        serverMutationGeneration: UInt64
    ) -> Bool {
        isEnabled
            && generation == operationGeneration
            && serverMutationGeneration == self.serverMutationGeneration
            && cachedTokenHex == tokenHex
    }

    private func performRegistrationRequest(_ request: URLRequest) async -> RegistrationResult {
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

    private func performDelete(
        _ request: URLRequest,
        preferenceGeneration: UInt64? = nil,
        serverMutationGeneration: UInt64? = nil
    ) async -> Bool {
        await networkMutationGate.withLock { [self] in
            if let preferenceGeneration {
                guard await self.isCurrentOptOut(preferenceGeneration) else {
                    return false
                }
            }
            if let serverMutationGeneration {
                guard await self.isCurrentServerMutation(
                    serverMutationGeneration
                ) else {
                    return false
                }
            }
            return await self.performDeleteRequest(request)
        } ?? false
    }

    private func beginServerMutation() -> UInt64 {
        serverMutationGeneration &+= 1
        return serverMutationGeneration
    }

    private func isCurrentServerMutation(_ generation: UInt64) -> Bool {
        generation == serverMutationGeneration
    }

    private func isCurrentOptOut(_ generation: UInt64) -> Bool {
        preferenceIntentGeneration == generation && !isEnabled
    }

    private func performDeleteRequest(_ request: URLRequest) async -> Bool {
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
        preferenceGeneration: UInt64? = nil
    ) async {
        guard let session = try? await tokenProvider
            .authenticatedSessionSnapshot() else { return }
        let currentAccountID = session.accountID
        let matching = pendingUnregisters.filter {
            $0.accountID == currentAccountID
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
                            sessionSnapshot: session,
                            preferenceGeneration: preferenceGeneration
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
        if matching.count > batch.count,
           results.contains(where: { $0.1 }) {
            schedulePendingUnregisterContinuation(
                preferenceGeneration: preferenceGeneration
            )
        }
    }

    private func persistPendingUnregister(tokenHex: String, accountID: String) {
        let entry = PendingUnregister(tokenHex: tokenHex, accountID: accountID)
        var queue = pendingUnregisters
        if !queue.contains(entry) {
            queue.append(entry)
        }
        // Never evict a privacy cleanup obligation merely to enforce a local
        // storage cap. The set is deduplicated by (account, token), and drains
        // in bounded network batches so size cannot stall current readiness.
        storePendingUnregisters(queue)
    }

    private func schedulePendingUnregisterContinuation(
        preferenceGeneration: UInt64? = nil
    ) {
        guard unregisterDrainTask == nil else { return }
        unregisterDrainTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.runPendingUnregisterContinuation(
                preferenceGeneration: preferenceGeneration
            )
        }
    }

    private func runPendingUnregisterContinuation(
        preferenceGeneration: UInt64?
    ) async {
        unregisterDrainTask = nil
        await retryPendingUnregisterIfPossible(
            preferenceGeneration: preferenceGeneration
        )
    }

    private func clearPendingUnregister(
        tokenHex: String,
        accountID: String
    ) {
        let filtered = pendingUnregisters.filter { entry in
            entry.tokenHex != tokenHex || entry.accountID != accountID
        }
        storePendingUnregisters(filtered)
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

    /// Returns the only owner that durable local state can prove for a token.
    /// A current auth session is deliberately not an ownership proof because
    /// it may already belong to the next account after sign-in races opt-out.
    private func persistedOwnerID(for tokenHex: String) -> String? {
        if let registeredOwnerID = defaults.string(
            forKey: Self.registeredAccountIDKey
        ), !registeredOwnerID.isEmpty {
            return registeredOwnerID
        }
        let owners = Set<String>(
            pendingUnregisters.compactMap { pending in
                guard pending.tokenHex == tokenHex,
                      !pending.accountID.isEmpty else { return nil }
                return pending.accountID
            }
        )
        guard owners.count == 1 else { return nil }
        return owners.first
    }

    private static func migrateLegacyPendingUnregisters(
        in defaults: UserDefaults
    ) {
        guard let tokenHex = defaults.string(
            forKey: pendingUnregisterTokenKey
        ), let accountID = defaults.string(
            forKey: pendingUnregisterAccountIDKey
        ), !tokenHex.isEmpty, !accountID.isEmpty else { return }
        var entries = (defaults.data(forKey: pendingUnregisterQueueKey)
            .flatMap { try? JSONDecoder().decode(
                [PendingUnregister].self,
                from: $0
            ) }) ?? []
        let legacy = PendingUnregister(
            tokenHex: tokenHex,
            accountID: accountID
        )
        if !entries.contains(legacy) { entries.append(legacy) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: pendingUnregisterQueueKey)
        }
        defaults.removeObject(forKey: pendingUnregisterTokenKey)
        defaults.removeObject(forKey: pendingUnregisterAccountIDKey)
    }

    private func storePendingUnregisters(_ entries: [PendingUnregister]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.pendingUnregisterQueueKey)
            defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
            defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.pendingUnregisterQueueKey)
        }
        defaults.removeObject(forKey: Self.pendingUnregisterTokenKey)
        defaults.removeObject(forKey: Self.pendingUnregisterAccountIDKey)
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

    /// Records that iOS failed to provide a device token for this attempt.
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

    private func cancelRetry() {
        operationGeneration = UUID()
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

/// Converts a persisted opt-out plus known server ownership into a durable
/// cleanup obligation before any asynchronous startup work begins.
private func persistDisabledPushRegistrationCleanupIfNeeded(
    in defaults: UserDefaults,
    enabledKey: String,
    cachedTokenKey: String,
    registeredAccountIDKey: String,
    pendingUnregisterQueueKey: String
) {
    // An absent preference is not an opt-out. Only a durably stored `false`
    // authorizes startup cleanup of an otherwise owned registration.
    guard defaults.object(forKey: enabledKey) as? Bool == false,
          let tokenHex = defaults.string(forKey: cachedTokenKey),
          !tokenHex.isEmpty,
          let accountID = defaults.string(forKey: registeredAccountIDKey),
          !accountID.isEmpty
    else { return }
    var entries = (defaults.data(forKey: pendingUnregisterQueueKey)
        .flatMap { try? JSONDecoder().decode(
            [PendingUnregister].self,
            from: $0
        ) }) ?? []
    let pending = PendingUnregister(
        tokenHex: tokenHex,
        accountID: accountID
    )
    if !entries.contains(pending) {
        entries.append(pending)
    }
    if let data = try? JSONEncoder().encode(entries) {
        defaults.set(data, forKey: pendingUnregisterQueueKey)
    }
}

private enum RegistrationResult {
    case cancelled
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
