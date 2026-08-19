import CMUXMobileCore
import CmuxAuthRuntime
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import OSLog

let mobileHostPeerLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-peer"
)

/// macOS composition root for the account-scoped peer host runtime, built on
/// `CmuxPeerTransport`. Owns auth observation, identity resolve, broker
/// registration, relay policy and credentials, endpoint activation, inbound
/// admission, per-session composition, route publication, and sign-out
/// preparation.
///
/// Deliberately deferred relative to the previous transport (no dead code
/// retained): Bonjour/LAN publication, custom relays at runtime, offline
/// first-pair invitations, and the durable pending-revocation outbox.
@MainActor
final class MobileHostPeerRuntime {
    static let shared = MobileHostPeerRuntime()

    static let capabilities = [
        "mobile-rpc-v1",
        "multistream-v1",
        MobileHostService.irohPrivatePathsCapability,
    ]
    #if DEBUG
    static let debugRelayOnlyDefaultsKey = "cmux.iroh.debug.relay-only"
    #endif

    /// Release-safe, bounded host-side connection timeline. Event payloads are
    /// fixed numeric categories, never peer identities, addresses, or tokens.
    let diagnosticLog: DiagnosticLog
    let identities: PeerIdentityRepository
    let appInstances = MobileHostPeerAppInstanceStore()
    let relayPolicyCache: PeerRelayPolicyCache
    let relayPolicyTrustRoot: PeerRelayPolicyTrustRoot?
    /// Account-scoped broker rate-limit floors that outlive runtime teardown.
    let brokerCooldowns = PeerBrokerCooldownLedger()
    /// The process's one iroh endpoint. Its identity comes from the account
    /// scope; a settings-driven rebind reuses the same secret key, so the
    /// EndpointID never rotates on a restart.
    let endpointManager = PeerEndpointManager()
    let authObserver = MobileHostIrohAuthObserver()

    weak var auth: AuthCoordinator?
    var authObservationTask: Task<Void, Never>?
    var transitionTask: Task<Void, Never>?
    var active: MobileHostPeerActiveRuntime?
    var desiredActive = false
    var observedAccountID: String?
    var activeAccountID: String?
    var lastKnownAccountID: String?
    var lastKnownTag: String?
    var lastKnownBindingID: String?
    var signOutIntentActive = false
    var signOutPreparationTask: Task<Void, Never>?
    var signOutPreparationRevision: UInt64 = 0
    var preparedSignOut: MobileHostPeerSignOutPreparation?
    var lifecycleRevision: UInt64 = 0
    var nextDiagnosticSessionID = 0
    /// Level-triggered failure rebuilder: every terminal failure arms exactly
    /// one pending rebuild through this task; any external wake collapses it.
    var failureRecoveryTask: Task<Void, Never>?
    var failureBackoff = PeerReconnectBackoff(profile: .host)
    var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var pendingRouteBinding: (revision: UInt64, binding: PeerBrokerBinding)?
    var lastFailureKind: DiagnosticFailureKind?
    /// Single-flight owner for revision reconciliation: one task in flight,
    /// later signals coalesce at the greatest observed revision.
    var serverSignalRefreshTask: Task<Void, Never>?
    var serverSignalPendingRevision: UInt64?

    private init() {
        diagnosticLog = Self.hostDiagnosticLog
        #if DEBUG
        identities = PeerIdentityRepository(
            secureStore: MobileHostPeerDevelopmentIdentityStore(
                directory: Self.developmentStoreDirectory(service: "identity")
            )
        )
        #else
        identities = PeerIdentityRepository()
        #endif
        relayPolicyCache = PeerRelayPolicyCache(store: MobileHostPeerRelayPolicyStore())
        relayPolicyTrustRoot = PeerRelayPolicyTrustRoot.appPinned(
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    /// The host diagnostic ring, deliberately `nonisolated` so read paths like
    /// the `iroh_diag` socket verb can snapshot it without a main-actor hop:
    /// the ring must stay exportable even when the main thread is wedged,
    /// which is exactly when connection diagnostics matter most.
    nonisolated static let hostDiagnosticLog = DiagnosticLog(
        buildStamp: MobileHostPeerRuntime.diagnosticBuildStamp,
        role: .macHost
    )

    private nonisolated static var diagnosticBuildStamp: String {
        DiagnosticBuildStamp.make(infoDictionary: Bundle.main.infoDictionary)
    }

    // MARK: - Lifecycle scheduling

    @discardableResult
    func scheduleReconcile(
        eraseAccountState: Bool,
        restartActiveRuntime: Bool = false
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        let previous = transitionTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == self.lifecycleRevision else { return }
            await self.reconcile(
                targetAccountID: self.signOutIntentActive
                    ? nil
                    : (self.desiredActive ? self.observedAccountID : nil),
                eraseAccountState: eraseAccountState || self.signOutIntentActive,
                restartActiveRuntime: restartActiveRuntime,
                revision: revision
            )
            if revision == self.lifecycleRevision {
                self.transitionTask = nil
            }
        }
        transitionTask = task
        return task
    }

    func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        restartActiveRuntime: Bool,
        revision: UInt64
    ) async {
        // Each transition re-derives failure recovery from its own outcome:
        // success resets the backoff ladder, failure re-arms it, and a
        // deactivating transition ends the need for it.
        cancelFailureRecovery(resetBackoff: false)
        if eraseAccountState {
            clearRoutePublication(revision: revision)
            await quarantineForSignOut()
        } else if restartActiveRuntime
                    || activeAccountID != targetAccountID
                    || targetAccountID == nil {
            clearRoutePublication(revision: revision)
            await teardownActiveRuntime()
        }

        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              let targetAccountID,
              active == nil else { return }

        diagnosticLog.record(DiagnosticEvent(
            .endpointStarting,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        do {
            try await activate(accountID: targetAccountID, revision: revision)
            failureBackoff.reset()
            lastFailureKind = nil
        } catch is CancellationError {
            return
        } catch {
            let failureKind = Self.diagnosticFailureKind(for: error)
            lastFailureKind = failureKind
            diagnosticLog.record(DiagnosticEvent(
                .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: failureKind.rawValue
            ))
            mobileHostPeerLog.error(
                "Peer host activation failed kind=\(failureKind.rawValue, privacy: .public) detail=\(String(describing: error), privacy: .private)"
            )
            publishIrohSettingsUpdate()
            scheduleFailureRecovery()
        }
    }

    /// Tears the active composition down as one unit: relay refresh, health
    /// watchdog, inbound listener, admitted-session tasks, then the endpoint.
    /// Endpoint teardown closes every peer-authorized connection and leaves
    /// Tailscale/other private-network sessions intact.
    func teardownActiveRuntime() async {
        guard let active else { return }
        self.active = nil
        activeAccountID = nil
        active.relayRefreshTask?.cancel()
        await active.watchdog?.stop()
        await active.listener.stop()
        let sessionTasks = Array(active.sessionTasks.values)
        active.sessionTasks.removeAll()
        for task in sessionTasks { task.cancel() }
        await endpointManager.deactivate()
        for task in sessionTasks { await task.value }
        MobileHostService.shared.closeAllIrohConnections()
        diagnosticLog.record(DiagnosticEvent(
            .endpointStopped,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        publishIrohSettingsUpdate()
    }

    nonisolated static func diagnosticFailureKind(
        for error: any Error
    ) -> DiagnosticFailureKind {
        DiagnosticFailureKind.classify(error)
    }

    func makeDiagnosticSessionID() -> Int {
        if nextDiagnosticSessionID == Int.max {
            nextDiagnosticSessionID = 1
        } else {
            nextDiagnosticSessionID += 1
        }
        return nextDiagnosticSessionID
    }

    // MARK: - External wakes

    func setDesiredActive(_ desired: Bool) {
        guard desiredActive != desired else {
            if desired { retryIfNeeded() }
            return
        }
        desiredActive = desired
        guard !signOutIntentActive else { return }
        scheduleReconcile(eraseAccountState: false)
    }

    /// External wake. Level-triggered: collapses any armed failure rebuild and
    /// re-derives the needed action from current state, so a stale wake-up is
    /// a no-op rather than a disruption.
    func retryIfNeeded() {
        guard !signOutIntentActive,
              desiredActive,
              observedAccountID != nil else { return }
        guard transitionTask == nil else { return }
        if active == nil {
            cancelFailureRecovery(resetBackoff: true)
            scheduleReconcile(eraseAccountState: false)
            return
        }
        if failureRecoveryTask != nil {
            cancelFailureRecovery(resetBackoff: true)
            scheduleReconcile(eraseAccountState: false, restartActiveRuntime: true)
        }
    }

    /// Arms one pending rebuild after bounded exponential backoff. Idempotent
    /// while an attempt is pending, so overlapping failure signals cannot
    /// double-schedule. Honors any account-scoped broker cooldown floor.
    func scheduleFailureRecovery() {
        guard failureRecoveryTask == nil,
              desiredActive,
              !signOutIntentActive,
              let accountID = observedAccountID else { return }
        failureRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let cooldown = await self.brokerCooldowns.activeCooldown(
                key: PeerBrokerCooldownLedger.Key(accountID: accountID)
            ) {
                self.failureBackoff.noteServerRetryAfter(cooldown)
            }
            let delay = self.failureBackoff.nextDelay()
            let milliseconds = delay.components.seconds * 1_000
                + delay.components.attoseconds / 1_000_000_000_000_000
            self.diagnosticLog.record(DiagnosticEvent(
                .retryScheduled,
                ms: UInt32(clamping: milliseconds),
                a: DiagnosticTransportKind.iroh.rawValue
            ))
            mobileHostPeerLog.error(
                "Peer host runtime failed; rebuild pending in \(delay.components.seconds)s"
            )
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.failureRecoveryTask = nil
            await self.recoverFailedRuntimeIfNeeded()
        }
    }

    /// Rebuilds the host runtime when it is absent while activation is
    /// desired. Level-triggered: the action is re-derived from current state.
    func recoverFailedRuntimeIfNeeded() async {
        guard desiredActive,
              !signOutIntentActive,
              observedAccountID != nil,
              transitionTask == nil,
              active == nil else { return }
        scheduleReconcile(eraseAccountState: false)
    }

    func cancelFailureRecovery(resetBackoff: Bool) {
        failureRecoveryTask?.cancel()
        failureRecoveryTask = nil
        if resetBackoff {
            failureBackoff.reset()
        }
    }

    /// A terminal failure observed outside a transition (endpoint recreate
    /// failed, listener died). Tears the composition down and arms one rebuild.
    func noteRuntimeFailure(_ error: any Error, revision: UInt64) async {
        guard revision == lifecycleRevision,
              let active, active.revision == revision else { return }
        let failureKind = Self.diagnosticFailureKind(for: error)
        lastFailureKind = failureKind
        diagnosticLog.record(DiagnosticEvent(
            .endpointFailed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: failureKind.rawValue
        ))
        clearRoutePublication(revision: revision)
        await teardownActiveRuntime()
        guard revision == lifecycleRevision else { return }
        scheduleFailureRecovery()
    }

    // MARK: - Auth observation

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
                    hasRuntime: self.active != nil,
                    transitionInFlight: self.transitionTask != nil
                ) else { continue }
                self.scheduleReconcile(
                    eraseAccountState: (state.accountID == nil
                        && (previousAccountID != nil
                            || self.activeAccountID != nil
                            || self.active != nil))
                        || (previousAccountID != nil
                            && previousAccountID != state.accountID)
                        || (self.activeAccountID != nil
                            && self.activeAccountID != state.accountID)
                )
            }
        }
    }

    static func shouldReconcileAuthObservation(
        accountID: String?,
        previousAccountID: String?,
        activeAccountID: String?,
        hasRuntime: Bool,
        transitionInFlight: Bool
    ) -> Bool {
        let hasRelevantState = accountID != nil
            || previousAccountID != nil
            || activeAccountID != nil
            || hasRuntime
        guard hasRelevantState else { return false }
        if accountID != previousAccountID { return true }
        if let activeAccountID, activeAccountID != accountID { return true }
        guard let accountID else { return hasRuntime }
        guard !transitionInFlight else { return false }
        return activeAccountID != accountID || !hasRuntime
    }

    // MARK: - Server connectivity signals

    /// An account-scoped invalidation says a newer authoritative route
    /// revision exists. One owned task performs a read-only reconciliation;
    /// bursts coalesce at the greatest revision instead of creating one waiter
    /// per frame. Terminal evidence rebuilds through the shared lifecycle path.
    func reconcileConnectivityFromServerSignal(revision: UInt64) {
        if serverSignalRefreshTask != nil {
            serverSignalPendingRevision = max(
                serverSignalPendingRevision ?? revision,
                revision
            )
            return
        }
        guard let signalRuntime = active else {
            retryIfNeeded()
            return
        }
        serverSignalRefreshTask = Task { @MainActor [weak self] in
            var bindingStillCurrent = true
            do {
                let response = try await signalRuntime.broker.connectivitySync(
                    knownRevision: revision
                )
                if response.changed, let snapshot = response.snapshot {
                    bindingStillCurrent = snapshot.bindings.contains {
                        $0.bindingID == signalRuntime.binding.bindingID
                            && $0.pairingEnabled
                    }
                }
            } catch {
                // Connectivity failure preserves the runtime; the next signal
                // or wake retries.
            }
            guard let self else { return }
            self.serverSignalRefreshTask = nil
            let replayRevision = self.serverSignalPendingRevision
            self.serverSignalPendingRevision = nil
            guard self.active === signalRuntime,
                  self.desiredActive,
                  !self.signOutIntentActive,
                  self.transitionTask == nil else { return }
            if !bindingStillCurrent {
                self.scheduleReconcile(
                    eraseAccountState: false,
                    restartActiveRuntime: true
                )
                return
            }
            if let replayRevision {
                self.reconcileConnectivityFromServerSignal(
                    revision: replayRevision
                )
            }
        }
    }

    // MARK: - Route publication

    /// Starts a new availability generation. Persisted broker identity is not
    /// a dialable route until the matching endpoint reports active.
    func beginRouteActivation(revision: UInt64) {
        guard revision == lifecycleRevision else { return }
        pendingRouteBinding = nil
        MobileHostService.shared.updateIrohRoute(identity: nil)
    }

    func stageRoute(_ binding: PeerBrokerBinding, revision: UInt64) {
        guard revision == lifecycleRevision else { return }
        lastKnownBindingID = binding.bindingID
        pendingRouteBinding = (revision: revision, binding: binding)
    }

    /// Publishes only the binding staged by the activation generation whose
    /// endpoint has completed activation.
    @discardableResult
    func publishRouteIfActive(revision: UInt64) -> Bool {
        guard revision == lifecycleRevision,
              let pendingRouteBinding,
              pendingRouteBinding.revision == revision else { return false }
        self.pendingRouteBinding = nil
        MobileHostService.shared.updateIrohRoute(
            identity: pendingRouteBinding.binding.endpointID,
            pathHints: pendingRouteBinding.binding.pathHints
        )
        return true
    }

    func clearRoutePublication(revision: UInt64? = nil) {
        if let revision, revision != lifecycleRevision { return }
        pendingRouteBinding = nil
        MobileHostService.shared.updateIrohRoute(identity: nil)
    }

    // MARK: - Sign-out

    /// Fences lifecycle work before auth begins its first asynchronous token
    /// read. Synchronous on purpose: the sign-out intent must be set before
    /// this call returns.
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

    /// Uses auth's captured tokens to revoke the exact preparation made before
    /// clear. Best-effort: a failed revoke logs and returns.
    func revokeAfterSignOut(
        accessToken: String?,
        refreshToken: String?
    ) async {
        observedAccountID = nil
        if let signOutPreparationTask {
            await signOutPreparationTask.value
        } else if preparedSignOut == nil {
            beginSignOutPreparation()
            await signOutPreparationTask?.value
        }
        defer {
            signOutIntentActive = false
            signOutPreparationTask = nil
        }

        guard let preparation = preparedSignOut,
              let bindingID = preparation.bindingID,
              let identity = preparation.identity,
              let endpointID = preparation.endpointID else {
            preparedSignOut = nil
            return
        }
        guard let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else { return }
        do {
            guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL else {
                throw MobileHostPeerRuntimeError.invalidBrokerBaseURL
            }
            let authorization = try PeerBindingRequestAuthorization(
                bindingID: bindingID,
                clientNamespace: preparation.clientNamespace,
                identity: identity,
                endpointID: endpointID
            )
            let credentials = PeerBrokerCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            let broker = try PeerTrustBrokerClient(
                baseURL: brokerBaseURL,
                // The pair was captured together up front, so it is coherent
                // by construction.
                tokenProvider: PeerBrokerTokenProvider(capture: { credentials }),
                clientNamespace: preparation.clientNamespace,
                bindingAuthorization: authorization
            )
            try await broker.revokeBinding(bindingID)
            preparedSignOut = nil
        } catch {
            mobileHostPeerLog.error(
                "Peer binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Stops the endpoint and captures the revocation intent before auth
    /// clears tokens, then wipes persisted account state per scope rules.
    func quarantineForSignOut() async {
        let accountID = activeAccountID ?? lastKnownAccountID
        if let accountID {
            preparedSignOut = MobileHostPeerSignOutPreparation(
                accountID: accountID,
                clientNamespace: active?.clientNamespace
                    ?? Self.macClientNamespace(
                        bundleIdentifier: Bundle.main.bundleIdentifier
                    ) ?? "mac:unknown",
                bindingID: active?.binding.bindingID ?? lastKnownBindingID,
                identity: active?.identity,
                endpointID: active?.identity.endpointID
            )
        }
        await teardownActiveRuntime()
        await wipePersistedAccountState()
        await diagnosticLog.clear()
    }

    func wipePersistedAccountState() async {
        do {
            try await identities.deactivate()
        } catch {
            mobileHostPeerLog.error(
                "Peer identity deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        appInstances.deactivate()
        // The relay-policy cache is deliberately retained: it is device-local
        // and its record is the monotonic rollback floor for signed policies.
        active = nil
        activeAccountID = nil
        lastKnownBindingID = nil
        lastKnownAccountID = nil
        lastKnownTag = nil
        publishIrohSettingsUpdate()
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

    // MARK: - Namespaces and tags

    /// Canonical `mac:<bundle-id>` broker namespace for this installed bundle.
    static func macClientNamespace(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        let trimmed = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed == bundleIdentifier,
              trimmed.contains("."),
              trimmed.utf8.count <= 251,
              trimmed.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return "mac:\(trimmed.lowercased())"
    }

    static func currentTag(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        MobileHostIdentity.instanceTag(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
    }

    #if DEBUG
    nonisolated static func developmentStoreDirectory(service: String) -> URL {
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
}

