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
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        if let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ), let mode = CmxIrohTransportVerificationMode(rawValue: rawValue) {
            return mode
        }
        return defaults.bool(forKey: debugRelayOnlyDefaultsKey)
            ? .relayOnly
            : .automatic
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
        if preparation.pendingRevocation == nil {
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
            let broker = try CmxIrohTrustBrokerClient(
                baseURL: brokerBaseURL,
                tokenSource: CmxIrohBrokerTokenSource(
                    accessToken: { accessToken },
                    refreshToken: { refreshToken }
                )
            )
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
            if !preparation.wasPersisted {
                await wipePersistedAccountState(
                    after: CmxIrohHostSignOutPreparation(
                        pendingRevocation: preparation.pendingRevocation,
                        wasPersisted: true
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
        if runtime != nil {
            let revision = lifecycleRevision
            Task { @MainActor [weak self] in
                guard let self,
                      self.desiredActive,
                      self.runtime != nil,
                      revision == self.lifecycleRevision else { return }
                await self.synchronizeLANPublicationWithSettings()
            }
            return
        }
        scheduleReconcile(eraseAccountState: false)
    }

    /// Applies the legacy-listener setting only to account-private Bonjour
    /// publication. The authenticated Iroh endpoint and broker binding remain
    /// active regardless, while enabling the listener later can publish the
    /// already-validated runtime without restarting it.
    func synchronizeLANPublicationWithSettings() async {
        guard MobileHostService.isListeningEnabled else {
            await lanPublisher.stop()
            return
        }
        guard desiredActive,
              let runtime,
              let context = await runtime.lanAdvertisementContext() else {
            await lanPublisher.stop()
            return
        }
        await lanPublisher.activate(
            rendezvous: context.rendezvous,
            binding: context.binding,
            directAddresses: { await runtime.localDirectAddresses() }
        )
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
            wasPersisted: wasPersisted
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
