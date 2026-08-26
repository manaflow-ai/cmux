import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import Foundation

extension MobileHostIrohRuntime {
    var transportVerificationMode: CmxIrohTransportVerificationMode {
        #if DEBUG
        Self.debugTransportVerificationMode(defaults: .standard)
        #else
        .automatic
        #endif
    }

    var protocolConfiguration: CmxIrohProtocolConfiguration {
        Self.protocolConfiguration(for: transportVerificationMode)
    }

    static func protocolConfiguration(
        for mode: CmxIrohTransportVerificationMode
    ) -> CmxIrohProtocolConfiguration {
        CmxIrohProtocolConfiguration(
            alpn: CmxIrohProtocolConfiguration.cmuxMobileV1.alpn,
            maximumHeaderByteCount: CmxIrohProtocolConfiguration.cmuxMobileV1.maximumHeaderByteCount,
            maximumConcurrentClientApplicationLaneCount:
                MobileHostIrohApplicationLaneRouter.maximumConcurrentLaneCount,
            allowsNATTraversalAfterAdmission: mode.allowsNATTraversalAfterAdmission
        )
    }

    #if DEBUG
    /// Resolves DEBUG overrides before the release-safe path preference.
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        if let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ), let mode = CmxIrohTransportVerificationMode(rawValue: rawValue) {
            return mode
        }
        if defaults.bool(forKey: debugRelayOnlyDefaultsKey) {
            return .relayOnly
        }
        return .automatic
    }

    static var isDebugRelayOnlyEnabled: Bool {
        debugTransportVerificationMode(defaults: .standard) == .relayOnly
    }
    #endif

    /// Fences lifecycle work before auth begins its first asynchronous token read.
    func beginSignOutPreparation() {
        guard signOutPreparationTask == nil else { return }
        signOutIntentActive = true
        signOutPreparationRevision &+= 1
        let task = scheduleReconcile(eraseAccountState: true)
        signOutPreparationTask = task
    }

    func prepareSignOut() async {
        beginSignOutPreparation()
        await signOutPreparationTask?.value
    }

    /// Uses auth's captured tokens to revoke the exact preparation made before clear.
    func revokeAfterSignOut(
        accessToken: String?,
        refreshToken: String?
    ) async {
        observedAccountID = nil
        if let signOutPreparationTask {
            guard await cancellationAwareWait(for: signOutPreparationTask) else {
                return
            }
        } else if preparedSignOut == nil {
            beginSignOutPreparation()
            if let signOutPreparationTask {
                guard await cancellationAwareWait(for: signOutPreparationTask) else {
                    return
                }
            }
        }
        defer {
            signOutIntentActive = false
            signOutPreparationTask = nil
        }

        guard var preparation = preparedSignOut else { return }
        guard let pendingRevocation = preparation.pendingRevocation else {
            preparedSignOut = nil
            return
        }
        preparation = await retryPersistingQuarantinedPreparation(preparation)

        guard let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else { return }
        do {
            guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL else {
                throw CmxIrohTrustBrokerClientError.invalidBaseURL
            }
            guard let clientNamespace = CmxIrohMacBundleNamespace(
                bundleIdentifier: Bundle.main.bundleIdentifier
            ) else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            let requestClientNamespace = preparation.bindingAuthorization?
                .clientNamespace ?? clientNamespace.rawValue
            let rawBroker = try CmxIrohTrustBrokerClient(
                baseURL: brokerBaseURL,
                tokenSource: CmxIrohBrokerTokenSource(
                    // The pair was captured together up front, so it is coherent
                    // by construction.
                    credentialPair: {
                        CmxIrohBrokerCredentials(
                            accessToken: accessToken,
                            refreshToken: refreshToken
                        )
                    }
                ),
                clientNamespace: requestClientNamespace,
                bindingAuthorization: preparation.bindingAuthorization,
                backpressureMode: .callerOwned
            )
            let broker = CmxIrohBackpressuredHostBroker(
                broker: rawBroker,
                gate: brokerBackpressureGate,
                accountID: pendingRevocation.accountID
            )
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
            if !preparation.wasPersisted {
                await wipePersistedAccountState(
                    after: CmxIrohHostSignOutPreparation(
                        pendingRevocation: preparation.pendingRevocation,
                        wasPersisted: true,
                        bindingAuthorization: preparation.bindingAuthorization
                    )
                )
            }
            if preparedSignOut?.pendingRevocation == preparation.pendingRevocation {
                preparedSignOut = nil
            }
        } catch {
            mobileHostIrohLog.error(
                "Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func cancellationAwareWait(
        for operation: Task<Void, Never>
    ) async -> Bool {
        let stream = AsyncStream<Void> { continuation in
            let waiter = Task { @MainActor in
                await operation.value
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                waiter.cancel()
            }
        }
        for await _ in stream {
            return true
        }
        return false
    }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let states = self.authObserver.states(for: auth)
            for await state in states {
                guard !Task.isCancelled else { return }
                let previousAccountID = self.observedAccountID
                self.observedAccountID = state.accountID
                if self.signOutIntentActive {
                    if state.accountID == nil {
                        self.releaseSignOutIntentAfterPreparation()
                    }
                    continue
                }
                guard Self.shouldReconcileAuthObservation(
                    accountID: state.accountID,
                    previousAccountID: previousAccountID,
                    activeAccountID: self.activeAccountID,
                    hasRuntime: self.runtime != nil,
                    transitionInFlight: self.transitionTask != nil,
                    preparedSignOutNeedsPersistence: self.preparedSignOut?.wasPersisted == false
                ) else { continue }
                self.scheduleReconcile(
                    eraseAccountState: (state.accountID == nil
                        && (previousAccountID != nil
                            || self.activeAccountID != nil
                            || self.runtime != nil))
                        || (previousAccountID != nil
                            && previousAccountID != state.accountID)
                        || (self.activeAccountID != nil
                            && self.activeAccountID != state.accountID)
                        || self.preparedSignOut?.wasPersisted == false
                )
            }
        }
    }

    static func shouldReconcileAuthObservation(
        accountID: String?,
        previousAccountID: String?,
        activeAccountID: String?,
        hasRuntime: Bool,
        transitionInFlight: Bool,
        preparedSignOutNeedsPersistence: Bool
    ) -> Bool {
        let hasRelevantState = accountID != nil
            || previousAccountID != nil
            || activeAccountID != nil
            || hasRuntime
        guard hasRelevantState else { return false }
        if preparedSignOutNeedsPersistence { return true }
        if accountID != previousAccountID { return true }
        if let activeAccountID, activeAccountID != accountID { return true }
        guard let accountID else { return hasRuntime }
        guard !transitionInFlight else { return false }
        return activeAccountID != accountID || !hasRuntime
    }

    private func releaseSignOutIntentAfterPreparation() {
        guard let signOutPreparationTask else {
            signOutIntentActive = false
            return
        }
        let revision = signOutPreparationRevision
        Task { @MainActor [weak self] in
            await signOutPreparationTask.value
            guard let self,
                  self.signOutPreparationRevision == revision,
                  self.observedAccountID == nil else { return }
            self.signOutIntentActive = false
            self.signOutPreparationTask = nil
        }
    }

    func setDesiredActive(_ desired: Bool) {
        guard desiredActive != desired else {
            if desired { retryIfNeeded() }
            return
        }
        desiredActive = desired
        guard !signOutIntentActive else { return }
        scheduleReconcile(eraseAccountState: false)
    }

    func retryIfNeeded() {
        guard !signOutIntentActive,
              desiredActive,
              observedAccountID != nil else { return }
        if preparedSignOut?.wasPersisted == false {
            scheduleReconcile(eraseAccountState: true)
            return
        }
        // Network-path observations are freshness hints, not ownership
        // transitions. The in-flight activation already observes endpoint
        // changes and replays one pending registration refresh after startup.
        guard transitionTask == nil else { return }
        guard let activeRuntime = runtime else {
            scheduleReconcile(eraseAccountState: false)
            return
        }
        let revision = lifecycleRevision
        cancelRetryInspection()
        retryInspectionRevision &+= 1
        let inspectionRevision = retryInspectionRevision
        retryInspectionTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.retryInspectionRevision == inspectionRevision {
                    self.retryInspectionTask = nil
                }
            }
            guard let self,
                  self.retryInspectionRevision == inspectionRevision,
                  self.desiredActive,
                  self.runtime === activeRuntime,
                  revision == self.lifecycleRevision else { return }
            if await activeRuntime.snapshot().state == .failed {
                guard self.desiredActive,
                      !self.signOutIntentActive,
                      self.runtime === activeRuntime,
                      self.retryInspectionRevision == inspectionRevision,
                      revision == self.lifecycleRevision else { return }
                // A fresh external signal resets the backoff ladder, then uses
                // the single guarded recovery entrypoint.
                self.retryInspectionTask = nil
                self.cancelFailureRecovery(resetBackoff: true)
                await self.recoverFailedRuntimeIfNeeded()
                return
            }
            guard self.runtime === activeRuntime,
                  revision == self.lifecycleRevision else { return }
            await self.synchronizeLANPublicationWithSettings()
        }
    }

    /// Arms one pending rebuild after bounded exponential backoff.
    ///
    /// `CmxIrohHostRuntime` fails closed on a non-transient broker rejection
    /// (for example 401/403/409): it tears the endpoint down into a terminal
    /// `.failed` phase so a rejected binding can never keep accepting
    /// connections. Recovery is owned here instead: every failure arms one
    /// rebuild through the shared `reconcile` path, and any external wake
    /// signal (`retryIfNeeded`, sign-in, settings) re-evaluates immediately,
    /// so a rejected registration recovers without an app relaunch.
    /// Idempotent while an attempt is pending, so overlapping failure signals
    /// (an activation throw plus the runtime's deactivation callback) cannot
    /// double-schedule.
    func scheduleFailureRecovery() {
        guard failureRecoveryTask == nil,
              desiredActive,
              !signOutIntentActive,
              observedAccountID != nil else { return }
        let delay = failureRecoverySchedule.delay(
            failureCount: failureRecoveryFailureCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: failureRecoveryJitter()
        )
        failureRecoveryFailureCount = min(failureRecoveryFailureCount + 1, 20)
        let clock = failureRecoveryClock
        let deadline = clock.now().addingTimeInterval(delay)
        mobileHostIrohLog.error(
            "Iroh host runtime failed; rebuild attempt \(self.failureRecoveryFailureCount) in \(Int(delay))s"
        )
        failureRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.failureRecoveryTask = nil
            await self.recoverFailedRuntimeIfNeeded()
        }
    }

    /// Rebuilds the host runtime when it is absent or terminally failed.
    /// Level-triggered: the action is re-derived from current state, so a
    /// stale wake-up is a no-op rather than a disruption.
    func recoverFailedRuntimeIfNeeded() async {
        guard desiredActive,
              !signOutIntentActive,
              observedAccountID != nil,
              transitionTask == nil else { return }
        guard let activeRuntime = runtime else {
            scheduleReconcile(eraseAccountState: false)
            return
        }
        let state = await activeRuntime.snapshot().state
        guard state == .failed,
              runtime === activeRuntime,
              transitionTask == nil,
              desiredActive,
              !signOutIntentActive else { return }
        scheduleReconcile(eraseAccountState: false, restartActiveRuntime: true)
    }

    /// Clears shared host state only while this deactivation still owns the
    /// composition-root lifecycle revision. Re-check after the suspending LAN
    /// stop so a replacement activation cannot be torn down by an older
    /// runtime's late callback.
    func handleActiveRuntimeDeactivation(
        revision: UInt64,
        stopLANPublication: @MainActor @Sendable () async -> Void,
        clearHostRuntime: @MainActor @Sendable () -> Void
    ) async {
        guard ownsDeactivationCleanup(revision: revision) else { return }
        await stopLANPublication()
        guard ownsDeactivationCleanup(revision: revision) else { return }
        clearHostRuntime()
        clearIrohRoutePublication(revision: revision)
        guard ownsDeactivationCleanup(revision: revision) else { return }
        await noteActiveRuntimeDeactivated(revision: revision)
    }

    private func ownsDeactivationCleanup(revision: UInt64) -> Bool {
        revision == lifecycleRevision
            && desiredActive
            && !signOutIntentActive
    }

    /// Invoked from the active runtime's deactivation handler. Deliberate
    /// stops (reconcile, settings restart, sign-out) bump `lifecycleRevision`
    /// before stopping, so a matching revision means the runtime tore itself
    /// down after a registration-refresh failure. Failed cold starts throw
    /// before `runtime` is assigned; `reconcile`'s failure path owns
    /// scheduling for those.
    func noteActiveRuntimeDeactivated(revision: UInt64) async {
        guard revision == lifecycleRevision,
              desiredActive,
              !signOutIntentActive,
              let activeRuntime = runtime else { return }
        let state = await activeRuntime.snapshot().state
        guard state == .failed,
              revision == lifecycleRevision,
              runtime === activeRuntime else { return }
        scheduleFailureRecovery()
    }

    func cancelFailureRecovery(resetBackoff: Bool) {
        cancelRetryInspection()
        failureRecoveryTask?.cancel()
        failureRecoveryTask = nil
        if resetBackoff {
            failureRecoveryFailureCount = 0
        }
    }

    func cancelRetryInspection() {
        retryInspectionRevision &+= 1
        retryInspectionTask?.cancel()
        retryInspectionTask = nil
    }

    /// Applies the legacy-listener setting only to account-private Bonjour
    /// publication. The authenticated Iroh endpoint and broker binding remain
    /// active regardless, while enabling the listener later can publish the
    /// already-validated runtime without restarting it.
    func synchronizeLANPublicationWithSettings() async {
        guard MobileHostService.isListeningEnabled else {
            await lanPublisher.stop()
            await recordLANPublicationState(reason: 1)
            return
        }
        guard desiredActive,
              let runtime,
              let context = await runtime.lanAdvertisementContext() else {
            await lanPublisher.stop()
            await recordLANPublicationState(reason: 2)
            return
        }
        await lanPublisher.activate(
            rendezvous: context.rendezvous,
            binding: context.binding,
            directAddresses: { await runtime.localDirectAddresses() }
        )
        await recordLANPublicationState(reason: 0)
    }

    /// Records the publisher's resulting state so relay-free bootstrap
    /// failures can distinguish a Mac that never advertised. `reason` is
    /// 0 settings applied, 1 listener setting disabled, 2 runtime context
    /// unavailable.
    private func recordLANPublicationState(reason: Int) async {
        let state: DiagnosticLANPublicationState =
            switch await lanPublisher.snapshot() {
            case .inactive: .inactive
            case .active: .active
            case .unavailable: .unavailable
            case .policyDenied: .policyDenied
            }
        diagnosticLog.record(DiagnosticEvent(
            .lanPublicationState,
            a: state.rawValue,
            b: reason
        ))
    }

    /// Stops the endpoint and durably quarantines its binding before auth clears tokens.
    func quarantineForSignOut() async {
        let preparation: CmxIrohHostSignOutPreparation
        if let runtime {
            preparation = await runtime.deactivateForSignOut()
        } else {
            preparation = await prepareWithoutRuntime()
        }
        preparedSignOut = preparation
        await lanPublisher.stop()
        if preparation.wasPersisted {
            await wipePersistedAccountState(after: preparation)
        } else {
            mobileHostIrohLog.error(
                "Iroh binding quarantine persistence failed; account state retained"
            )
        }
        await diagnosticLog.clear()
    }

    func prepareWithoutRuntime() async -> CmxIrohHostSignOutPreparation {
        let pending: CmxIrohPendingRevocation?
        if preparedSignOut?.wasPersisted == false {
            pending = preparedSignOut?.pendingRevocation
        } else {
            pending = currentPendingRevocation()
                ?? preparedSignOut?.pendingRevocation
        }
        var wasPersisted = pending == nil || preparedSignOut?.wasPersisted == true
        if let pending, !wasPersisted {
            do {
                try await pendingRevocations.enqueue(pending)
                wasPersisted = true
            } catch {
                mobileHostIrohLog.error(
                    "Iroh binding quarantine persistence failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
        return CmxIrohHostSignOutPreparation(
            pendingRevocation: pending,
            wasPersisted: wasPersisted,
            bindingAuthorization: preparedSignOut?.bindingAuthorization
        )
    }

    func retryPersistingQuarantinedPreparation(
        _ preparation: CmxIrohHostSignOutPreparation
    ) async -> CmxIrohHostSignOutPreparation {
        guard !preparation.wasPersisted else { return preparation }
        let retried: CmxIrohHostSignOutPreparation
        if let runtime {
            retried = await runtime.deactivateForSignOut()
        } else {
            retried = await prepareWithoutRuntime()
        }
        guard retried.pendingRevocation == preparation.pendingRevocation else {
            mobileHostIrohLog.error(
                "Iroh binding quarantine retry returned a different binding"
            )
            return preparation
        }
        preparedSignOut = retried
        if retried.wasPersisted {
            await wipePersistedAccountState(after: retried)
        }
        return retried
    }

    func wipePersistedAccountState(
        after preparation: CmxIrohHostSignOutPreparation
    ) async {
        guard preparation.wasPersisted else { return }
        let accountID = activeAccountID ?? lastKnownAccountID
        do {
            try await hostPolicies.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh offline policy deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        do {
            try await brokerCredentials.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh broker credential deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        do {
            try await identities.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh identity deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        if let accountID {
            try? await relayPreferenceStore.deactivate(accountID: accountID)
            try? await customRelayCredentials.deactivate(accountID: accountID)
        }
        await appInstances.deactivate()
        clearRelayPolicyRuntimeState()
        runtime = nil
        activeAccountID = nil
        activeAppInstanceID = nil
        lastKnownBindingID = nil
        lastKnownAccountID = nil
        lastKnownTag = nil
    }

    func currentPendingRevocation() -> CmxIrohPendingRevocation? {
        guard let accountID = lastKnownAccountID ?? activeAccountID,
              let tag = lastKnownTag,
              let bindingID = lastKnownBindingID else { return nil }
        return try? CmxIrohPendingRevocation(
            accountID: accountID,
            tag: tag,
            bindingID: bindingID
        )
    }

    #if DEBUG
    static func developmentStoreDirectory(service: String) -> URL {
        let rawBundleScope = Bundle.main.bundleIdentifier
            ?? "com.cmuxterm.app.debug"
        let bundleScope = String(rawBundleScope.map { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || ["-", ".", "_"].contains(character))
                ? character
                : "_"
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("iroh-debug", isDirectory: true)
            .appendingPathComponent(bundleScope, isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
    }
    #endif

    static func currentTag(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        MobileHostIdentity.instanceTag(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
    }
}

#if DEBUG
extension MobileHostIrohRuntime: CmxIrohDebugSettingsControlling {
    func setIrohDebugRelayOnly(_ enabled: Bool) async throws {
        let mode: CmxIrohTransportVerificationMode = enabled ? .relayOnly : .automatic
        await setIrohDebugTransportVerificationMode(mode)
    }

    /// Applies one Debug-only path constraint through the same runtime restart
    /// boundary used by Settings and the Debug menu.
    func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async {
        guard transportVerificationMode != mode else { return }
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        UserDefaults.standard.removeObject(forKey: Self.debugRelayOnlyDefaultsKey)
        publishIrohSettingsUpdate()
        await scheduleReconcile(
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }
}
#endif
