public import Observation

/// Owns the optional system VPN that lets Safari and other apps reach Cloud
/// machines' private addresses.
///
/// Separate from ``CloudSessionController``'s in-process tunnel in every
/// way: it is its own WireGuard peer (enrolled under the `browser` purpose
/// with its own key, so the two never contend for one peer), it runs in the
/// packet tunnel extension that iOS owns, and it starts only when the user
/// turns it on. Leaving the Cloud tab or backgrounding the app does not stop
/// it. Signing out, or switching to another account, removes it.
///
/// The key is minted on each enable and stored only inside the saved
/// configuration, so it never touches the terminal tunnel's identity item.
@MainActor
@Observable
public final class CloudSystemVPNController {
    /// The VPN's state as the user sees it.
    public private(set) var phase: CloudSystemVPNPhase = .off

    private let service: any CloudVMServing
    private let identityResolver: CloudDeviceIdentityResolver
    private let manager: any CloudSystemVPNManaging
    private let deviceName: String
    private let routePolicy = CloudVPNRoutePolicy()
    private let timeout: CloudSystemVPNTaskTimeout
    private let revocationWorker: CloudSystemVPNRevocationWorker
    private let operationTimeout: Duration
    private let operationGate = CloudSystemVPNOperationGate()
    private let cleanupRetryCount: Int
    // The durable store is the source of truth; this cache is only the
    // bounded working set used while an account transition is in flight.
    // Match the durable store's fixed capacity so loading persisted work
    // never strands entries beyond the in-memory cleanup set.
    private let maxInMemoryPendingRevocations = 4096
    // Account transitions do one bounded unit of remote cleanup. Remaining
    // entries continue through the background retry path after the new scope
    // is ready.
    private let maxPendingRevocationsPerTransition = 1
    private let maxPendingRevocationsPerRetry = 8
    private let credentials: @Sendable () async -> CloudAPITokenSource.TokenPair?
    private let pendingRevocationStore: any CloudSystemVPNPendingRevocationStoring
    private var scope: String?
    private var scopeTeamID: String?
    private var hasLoadedScope = false
    private var cleanupPending = false
    private var browserTunnel: (
        scope: String,
        deviceFingerprint: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    )?
    private var browserTunnelGeneration: UInt64?
    private var pendingBrowserTunnelRevocations: [(
        scope: String,
        deviceFingerprint: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    )] = []
    private var needsPlatformReconciliation = false
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var enableRetryTask: Task<Void, Never>?
    private var enableRetryRequested = false
    private var cleanupRetryTask: Task<Void, Never>?
    private var cleanupRetryRequested = false
    private var transitionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - service: The `/api/vm` client, for enrollment.
    ///   - identityStore: The device identity store; only its fingerprint is
    ///     used, so the VPN peer is filed under the same device as the
    ///     terminal tunnel.
    ///   - manager: The platform VPN boundary.
    ///   - deviceName: This phone's name, sent on enrollment.
    ///   - operationTimeout: Maximum time allowed for one Cloud or Network
    ///     Extension operation.
    ///   - cleanupRetryCount: Number of attempts made to remove an old VPN
    ///     profile before leaving cleanup pending for a later retry.
    ///   - credentials: Captures the active account's token pair so a peer
    ///     enrolled before an account switch can be revoked with its owner.
    ///   - pendingRevocationStore: Durable fingerprints for server revocations
    ///     that must be retried after a controller or session is recreated.
    ///
    /// The team ID is supplied to ``setScope(_:teamID:)`` and is captured
    /// with the token pair for every explicit revocation.
    public init(
        service: any CloudVMServing,
        identityStore: any CloudDeviceIdentityStoring,
        manager: any CloudSystemVPNManaging,
        deviceName: String,
        operationTimeout: Duration = .seconds(30),
        cleanupRetryCount: Int = 3,
        credentials: @escaping @Sendable () async -> CloudAPITokenSource.TokenPair? = { nil },
        pendingRevocationStore: any CloudSystemVPNPendingRevocationStoring
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.manager = manager
        self.deviceName = deviceName
        self.credentials = credentials
        self.pendingRevocationStore = pendingRevocationStore
        let boundedTimeout = max(.milliseconds(1), operationTimeout)
        timeout = CloudSystemVPNTaskTimeout(timeout: boundedTimeout)
        revocationWorker = CloudSystemVPNRevocationWorker(
            service: service,
            timeout: timeout
        )
        self.operationTimeout = boundedTimeout
        self.cleanupRetryCount = max(1, cleanupRetryCount)
        manager.onPhaseChange = { [weak self] phase in
            guard let self,
                  self.scope != nil,
                  self.operation == nil,
                  !self.needsPlatformReconciliation,
                  !self.operationGate.hasPendingOperation else { return }
            self.accept(phase)
        }
    }

    /// Whether this device can run the VPN at all.
    public var isAvailable: Bool { manager.isAvailable }

    /// Binds the VPN to an account scope, or to none when signed out.
    ///
    /// A VPN saved under another scope is removed before anything else, so
    /// one account's routes never survive into another's session.
    public func setScope(_ newScope: String?, teamID: String? = nil) {
        let newScopeTeamID = newScope == nil ? nil : normalizedTeamID(teamID)
        if hasLoadedScope,
           scope == newScope,
           scopeTeamID == newScopeTeamID,
           cleanupPending,
           operation != nil {
            return
        }
        guard !hasLoadedScope
            || scope != newScope
            || scopeTeamID != newScopeTeamID
            || cleanupPending
        else { return }
        hasLoadedScope = true
        enableRetryRequested = false
        enableRetryTask?.cancel()
        enableRetryTask = nil
        cleanupRetryRequested = false
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        let previousScope = scope
        if let browserTunnel,
           browserTunnel.scope != newScope
               || browserTunnel.teamID != newScopeTeamID {
            rememberPendingBrowserTunnelRevocation(browserTunnel)
        }
        scope = newScope
        scopeTeamID = newScopeTeamID
        let removesExistingConfiguration =
            previousScope != nil || newScope == nil || cleanupPending
        cleanupPending = removesExistingConfiguration
        enqueue { [self] generation in
            var remoteCleanupError: (any Error)?
            do {
                await loadPersistedBrowserTunnelRevocations(
                    scopes: [previousScope, newScope]
                )
                await persistPendingBrowserTunnelRevocations()
                guard manager.isAvailable else {
                    guard self.isCurrent(generation) else { return }
                    browserTunnel = nil
                    return
                }
                if !pendingBrowserTunnelRevocations.isEmpty {
                    do {
                        let hasDeferredCleanup = try await revokePendingBrowserTunnel(
                            limit: maxPendingRevocationsPerTransition
                        )
                        if hasDeferredCleanup {
                            scheduleCleanupRetry()
                        }
                    } catch {
                        remoteCleanupError = error
                    }
                    guard self.isCurrent(generation) else { return }
                    browserTunnel = nil
                }
                if removesExistingConfiguration {
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                }
                if let newScope {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: newScope, teamID: newScopeTeamID)
                    }
                    guard self.isCurrent(generation) else { return }
                    needsPlatformReconciliation = false
                }
                if let remoteCleanupError {
                    throw remoteCleanupError
                }
                publish(manager.phase)
            } catch {
                guard self.isCurrent(generation) else { return }
                publish(.failed(.configuration))
            }
        }
    }

    /// Re-reads the live status, for example when the app returns to the
    /// foreground after the user changed the VPN in Settings.
    public func refresh() async {
        guard manager.isAvailable, operation == nil else { return }
        guard let scope else {
            guard cleanupPending || !pendingBrowserTunnelRevocations.isEmpty else { return }
            enqueue { [self] generation in
                do {
                    if !pendingBrowserTunnelRevocations.isEmpty {
                        let hasDeferredCleanup = try await revokePendingBrowserTunnel(
                            limit: maxPendingRevocationsPerRetry
                        )
                        if hasDeferredCleanup {
                            scheduleCleanupRetry()
                        }
                        guard self.isCurrent(generation) else { return }
                        browserTunnel = nil
                    }
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                    publish(manager.phase)
                } catch {
                    guard self.isCurrent(generation) else { return }
                    publish(.failed(.configuration))
                }
            }
            await waitForPendingOperation()
            return
        }
        enqueue { [self] generation in
            let requestedTeamID = scopeTeamID
            do {
                if !pendingBrowserTunnelRevocations.isEmpty {
                    let hasDeferredCleanup = try await revokePendingBrowserTunnel(
                        limit: maxPendingRevocationsPerRetry
                    )
                    if hasDeferredCleanup {
                        scheduleCleanupRetry()
                    }
                    guard self.isCurrent(generation) else { return }
                    browserTunnel = nil
                }
                if cleanupPending {
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                }
                try await performBounded(reconcilePlatformOnTimeout: true) {
                    try await self.manager.refresh(scope: scope, teamID: requestedTeamID)
                }
                guard self.isCurrent(generation) else { return }
                needsPlatformReconciliation = false
                accept(manager.phase)
            } catch {
                guard self.isCurrent(generation) else { return }
                publish(.failed(.configuration))
            }
        }
        await waitForPendingOperation()
    }

    /// The user turned the VPN on. iOS owns consent and the connection.
    public func enable() {
        guard manager.isAvailable else {
            publish(.failed(.unavailable))
            return
        }
        guard let scope else {
            if cleanupPending {
                retryPendingCleanup()
                return
            }
            publish(.failed(.enrollment))
            return
        }
        guard !cleanupPending, pendingBrowserTunnelRevocations.isEmpty else {
            if manager.isAvailable {
                retryPendingCleanup()
                return
            }
            publish(.failed(.configuration))
            return
        }
        if operationGate.hasPendingOperation {
            publish(.preparing)
            scheduleEnableRetry()
            return
        }
        if !needsPlatformReconciliation {
            switch phase {
            case .preparing, .connecting, .connected, .disconnecting: return
            case .off, .failed: break
            }
        }
        let shouldReconcile = needsPlatformReconciliation || !phase.isRequestedOn
        let ownerTeamID = scopeTeamID
        publish(.preparing)
        enqueue { [self] generation in
            do {
                if shouldReconcile {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: scope, teamID: ownerTeamID)
                    }
                    guard self.isCurrent(generation),
                          self.scope == scope,
                          self.scopeTeamID == ownerTeamID
                    else {
                        throw CancellationError()
                    }
                    needsPlatformReconciliation = false
                    if manager.phase.isRequestedOn {
                        publish(manager.phase)
                        return
                    }
                }
                let keyPair = WireGuardKeyPair()
                let attempt = EnableAttempt()
                try await performBounded(
                    reconcilePlatformOnTimeout: true,
                    onTimeout: { attempt.invalidate() }
                ) {
                    let tokenPair = await self.credentials()
                    let credentials = tokenPair.map { pair in
                        CloudAPITokenSource.TokenContext(
                            accessToken: pair.accessToken,
                            refreshToken: pair.refreshToken,
                            teamID: ownerTeamID
                        )
                    }
                    let identity: CloudDeviceIdentity
                    do {
                        identity = try await self.identityResolver.resolve()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw CloudSystemVPNError.enrollment
                    }
                    let enrollment: CloudTunnelEnrollment
                    do {
                        enrollment = try await self.service.enrollTunnel(
                            clientPublicKey: keyPair.publicKey,
                            deviceFingerprint: identity.fingerprint,
                            tunnelPurpose: .browser,
                            deviceName: self.deviceName,
                            credentials: credentials
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw CloudSystemVPNError.enrollment
                    }
                    guard attempt.isValid,
                          self.isCurrent(generation),
                          self.scope == scope,
                          self.scopeTeamID == ownerTeamID
                    else {
                        await self.revokeEnrollmentIfOwned(
                            enrollment,
                            scope: scope,
                            teamID: ownerTeamID,
                            credentials: credentials
                        )
                        throw CancellationError()
                    }
                    try await self.install(
                        enrollment: enrollment,
                        privateKey: keyPair.privateKey,
                        scope: scope,
                        teamID: ownerTeamID,
                        credentials: credentials
                    )
                    guard attempt.isValid,
                          self.isCurrent(generation),
                          self.scope == scope,
                          self.scopeTeamID == ownerTeamID
                    else {
                        await self.removeLateInstallation()
                        await self.revokeEnrollmentIfOwned(
                            enrollment,
                            scope: scope,
                            teamID: ownerTeamID,
                            credentials: credentials
                        )
                        throw CancellationError()
                    }
                    self.browserTunnel = (
                        scope: scope,
                        deviceFingerprint: enrollment.deviceFingerprint,
                        teamID: credentials?.teamID ?? self.scopeTeamID,
                        credentials: credentials
                    )
                    self.browserTunnelGeneration = generation
                }
                guard self.isCurrent(generation) else { return }
                publish(manager.phase == .off ? .connecting : manager.phase)
            } catch {
                guard self.isCurrent(generation) else { return }
                publish(.failed((error as? CloudSystemVPNError) ?? .configuration))
            }
        }
    }

    private func install(
        enrollment: CloudTunnelEnrollment,
        privateKey: String,
        scope: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    ) async throws {
        do {
            guard permitsOnlyPrivateRoutes(enrollment) else {
                throw CloudSystemVPNError.configuration
            }
            let configuration: WireGuardQuickConfig
            do {
                configuration = try WireGuardQuickConfig.make(
                    enrollment: enrollment,
                    privateKey: privateKey
                )
            } catch {
                throw CloudSystemVPNError.configuration
            }
            // The text is what gets installed, and the server may have
            // supplied it whole; the enrollment-field check above cannot
            // vouch for it.
            guard routePolicy.permitsOnlyPrivateRoutes(inQuickConfig: configuration.text) else {
                throw CloudSystemVPNError.configuration
            }
            try await manager.installAndStart(
                configuration: configuration.text,
                scope: scope,
                teamID: teamID
            )
        } catch {
            guard enrollment.created || enrollment.rotated else { throw error }
            await revokeEnrollmentIfOwned(
                enrollment,
                scope: scope,
                teamID: teamID,
                credentials: credentials
            )
            throw error
        }
    }

    private func removeLateInstallation() async {
        manager.cancelPendingOperation()
        do {
            // This runs inside the operation gate that owns the late install.
            // Await the platform removal here so the gate cannot release
            // while Network Extension is still tearing down the profile.
            try await manager.stop(removeConfiguration: true)
            cleanupPending = false
            needsPlatformReconciliation = false
        } catch {
            cleanupPending = true
        }
    }

    /// Returns the sign-out teardown that revokes this phone's browser role
    /// with the tokens captured before auth clears them.
    public func serverTeardown() -> @Sendable (String?, String?) async -> Void {
        let controller = self
        let identityResolver = self.identityResolver
        let attempts = cleanupRetryCount
        let creationScope = scope
        let creationTeamID = scopeTeamID
        let creationTunnels = browserTunnelsForTeardown()
        let creationBrowserTunnelGeneration = browserTunnelGeneration
        return { accessToken, refreshToken in
            let gateReady = await controller.waitForPendingOperationAndGate()
            var enrolled = creationTunnels.filter { tunnel in
                tunnel.scope == creationScope
            }
            if enrolled.isEmpty {
                guard let scope = creationScope,
                      let fingerprint = try? await identityResolver.stored()?.fingerprint
                else { return }
                enrolled = [(
                    scope: scope,
                    deviceFingerprint: fingerprint,
                    teamID: creationTeamID,
                    credentials: nil
                )]
            }
            guard gateReady else {
                for tunnel in enrolled {
                    await controller.rememberAndPersistPendingBrowserTunnelRevocation(tunnel)
                }
                return
            }
            guard let accessToken, let refreshToken else {
                for tunnel in enrolled {
                    await controller.rememberAndPersistPendingBrowserTunnelRevocation(tunnel)
                }
                return
            }
            await controller.revokeServerTunnelsSerially(
                enrolled,
                expectedScope: creationScope,
                expectedBrowserTunnelGeneration: creationBrowserTunnelGeneration,
                fallbackCredentials: CloudAPITokenSource.TokenContext(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    teamID: creationTeamID
                ),
                attempts: attempts
            )
        }
    }

    /// The user turned the VPN off. The configuration stays saved so iOS
    /// Settings can still show it; signing out removes it.
    public func disable() {
        if scope == nil && cleanupPending {
            retryPendingCleanup()
            return
        }
        publish(.disconnecting)
        enqueue { [self] generation in
            do {
                try await performBounded(reconcilePlatformOnTimeout: true) {
                    try await self.manager.stop(removeConfiguration: false)
                }
                guard self.isCurrent(generation) else { return }
                accept(manager.phase)
            } catch {
                guard self.isCurrent(generation) else { return }
                publish(.failed(.configuration))
            }
        }
    }

    /// Retries the action represented by the current failure row. Pending
    /// cleanup is completed before a new account is refreshed or enrolled.
    public func retry() {
        if cleanupPending || !pendingBrowserTunnelRevocations.isEmpty {
            retryPendingCleanup()
        } else {
            enable()
        }
    }

    /// Waits for queued saves and removals. Operations run one at a time,
    /// including while the iOS consent prompt is open.
    public func waitForPendingOperation() async { await operation?.value }

    /// Waits for sign-out cleanup and for any late Cloud or Network Extension
    /// operation that still owns the serialized gate, with a bounded wait.
    @discardableResult
    public func waitForPendingOperationAndGate() async -> Bool {
        if let pendingOperation = operation {
            let wait = Task<Void, any Error> {
                await pendingOperation.value
            }
            do {
                try await CloudSystemVPNTaskTimeout(
                    timeout: max(operationTimeout, .seconds(1))
                ).value(wait)
            } catch {
                wait.cancel()
                return false
            }
        }
        return await waitForOperationGate()
    }

    private func waitForOperationGate() async -> Bool {
        let idle = Task<Void, any Error> { [operationGate] in
            await operationGate.waitForIdle()
        }
        do {
            try await CloudSystemVPNTaskTimeout(
                timeout: max(operationTimeout, .seconds(1))
            ).value(idle)
            return true
        } catch {
            idle.cancel()
            return false
        }
    }

    private func accept(_ status: CloudSystemVPNPhase) {
        // A declined consent prompt reports `.off` right after the failure;
        // keep the failure so its recovery actions stay visible.
        if case .failed = phase, status == .off { return }
        publish(status)
    }

    private func publish(_ status: CloudSystemVPNPhase) {
        transitionTask?.cancel()
        transitionTask = nil
        phase = status
        guard status == .connecting || status == .disconnecting else { return }
        let expected = status
        let timeout = operationTimeout
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.phase == expected else { return }
            let livePhase = self.manager.phase
            switch (expected, livePhase) {
            case (.connecting, .connected), (.disconnecting, .off):
                self.publish(livePhase)
            case (_, .failed(let error)):
                self.publish(.failed(error))
            default:
                self.publish(.failed(.configuration))
            }
        }
    }

    /// The routes and interface addresses an enrollment would install must
    /// all be private. An enrollment with no routes routes nothing.
    private func permitsOnlyPrivateRoutes(_ enrollment: CloudTunnelEnrollment) -> Bool {
        guard !enrollment.routes.isEmpty else { return false }
        var cidrs = enrollment.routes
        if let v4 = enrollment.addressV4 { cidrs.append(v4.contains("/") ? v4 : v4 + "/32") }
        if let v6 = enrollment.addressV6 { cidrs.append(v6.contains("/") ? v6 : v6 + "/128") }
        return cidrs.allSatisfy(routePolicy.permits)
    }

    private func removeConfigurationWithRetry() async throws {
        var lastError: (any Error)?
        for _ in 0..<cleanupRetryCount {
            do {
                try await performBounded(
                    reconcileCleanupOnTimeout: true,
                    retainPendingOperationOnTimeout: true
                ) {
                    try await self.manager.stop(removeConfiguration: true)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch is CloudSystemVPNTaskTimeout.Failure {
                throw CloudSystemVPNTaskTimeout.Failure.timedOut
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CloudSystemVPNError.configuration
    }

    private func rememberPendingBrowserTunnelRevocation(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) {
        let tunnelTeamID = normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
        if let index = pendingBrowserTunnelRevocations.firstIndex(where: {
            $0.scope == tunnel.scope
                && $0.deviceFingerprint == tunnel.deviceFingerprint
                && normalizedTeamID($0.teamID) == tunnelTeamID
        }) {
            let existing = pendingBrowserTunnelRevocations[index]
            pendingBrowserTunnelRevocations[index] = (
                scope: existing.scope,
                deviceFingerprint: existing.deviceFingerprint,
                teamID: normalizedTeamID(existing.teamID) ?? tunnelTeamID,
                credentials: existing.credentials ?? tunnel.credentials
            )
            return
        }
        pendingBrowserTunnelRevocations.append((
            scope: tunnel.scope,
            deviceFingerprint: tunnel.deviceFingerprint,
            teamID: tunnelTeamID,
            credentials: tunnel.credentials
        ))
        let overflow = pendingBrowserTunnelRevocations.count - maxInMemoryPendingRevocations
        if overflow > 0 {
            pendingBrowserTunnelRevocations.removeFirst(overflow)
        }
    }

    private func clearPendingBrowserTunnelRevocationCredentials(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) {
        guard let index = pendingBrowserTunnelRevocations.firstIndex(where: {
            $0.scope == tunnel.scope
                && $0.deviceFingerprint == tunnel.deviceFingerprint
                && normalizedTeamID($0.teamID)
                    == normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
        }) else { return }
        pendingBrowserTunnelRevocations[index] = (
            scope: tunnel.scope,
            deviceFingerprint: tunnel.deviceFingerprint,
            teamID: normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID),
            credentials: nil
        )
    }

    private func removePendingBrowserTunnelRevocation(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) {
        pendingBrowserTunnelRevocations.removeAll {
            $0.scope == tunnel.scope
                && $0.deviceFingerprint == tunnel.deviceFingerprint
                && normalizedTeamID($0.teamID)
                    == normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
        }
    }

    private func loadPersistedBrowserTunnelRevocations(scopes: [String?]) async {
        var loadedScopes = Set<String>()
        for scope in scopes.compactMap({ $0 }) where loadedScopes.insert(scope).inserted {
            for revocation in await pendingRevocationStore.load(scope: scope) {
                rememberPendingBrowserTunnelRevocation((
                    scope: scope,
                    deviceFingerprint: revocation.deviceFingerprint,
                    teamID: normalizedTeamID(revocation.teamID),
                    credentials: nil
                ))
            }
        }
    }

    private func persistPendingBrowserTunnelRevocation(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) async {
        var revocations = await pendingRevocationStore.load(scope: tunnel.scope)
        let pending = CloudSystemVPNPendingRevocation(
            deviceFingerprint: tunnel.deviceFingerprint,
            teamID: normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
        )
        if let existing = revocations.first(where: {
            $0.deviceFingerprint == pending.deviceFingerprint
                && normalizedTeamID($0.teamID) == pending.teamID
        }) {
            revocations.remove(existing)
            revocations.insert(
                CloudSystemVPNPendingRevocation(
                    deviceFingerprint: pending.deviceFingerprint,
                    teamID: pending.teamID
                )
            )
        } else {
            revocations.insert(pending)
        }
        await pendingRevocationStore.save(revocations, scope: tunnel.scope)
    }

    private func persistPendingBrowserTunnelRevocations() async {
        var revocationsByScope: [String: Set<CloudSystemVPNPendingRevocation>] = [:]
        for tunnel in pendingBrowserTunnelRevocations {
            var revocations: Set<CloudSystemVPNPendingRevocation>
            if let loaded = revocationsByScope[tunnel.scope] {
                revocations = loaded
            } else {
                revocations = await pendingRevocationStore.load(scope: tunnel.scope)
            }
            let pending = CloudSystemVPNPendingRevocation(
                deviceFingerprint: tunnel.deviceFingerprint,
                teamID: normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
            )
            if let existing = revocations.first(where: {
                $0.deviceFingerprint == pending.deviceFingerprint
                    && normalizedTeamID($0.teamID) == pending.teamID
            }) {
                revocations.remove(existing)
            }
            revocations.insert(pending)
            revocationsByScope[tunnel.scope] = revocations
        }
        for (scope, revocations) in revocationsByScope {
            await pendingRevocationStore.save(revocations, scope: scope)
        }
    }

    private func rememberAndPersistPendingBrowserTunnelRevocation(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) async {
        rememberPendingBrowserTunnelRevocation(tunnel)
        await persistPendingBrowserTunnelRevocation(tunnel)
    }

    private func clearPersistedBrowserTunnelRevocation(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )
    ) async {
        var revocations = await pendingRevocationStore.load(scope: tunnel.scope)
        revocations = revocations.filter {
            $0.deviceFingerprint != tunnel.deviceFingerprint
                || normalizedTeamID($0.teamID)
                    != normalizedTeamID(tunnel.teamID ?? tunnel.credentials?.teamID)
        }
        await pendingRevocationStore.save(revocations, scope: tunnel.scope)
    }

    private func browserTunnelsForTeardown() -> [(
        scope: String,
        deviceFingerprint: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    )] {
        var tunnels = pendingBrowserTunnelRevocations
        if let browserTunnel,
           !tunnels.contains(where: {
               $0.scope == browserTunnel.scope
                   && $0.deviceFingerprint == browserTunnel.deviceFingerprint
                   && normalizedTeamID($0.teamID)
                       == normalizedTeamID(browserTunnel.teamID)
           }) {
            tunnels.append(browserTunnel)
        }
        return tunnels
    }

    private func revokePendingBrowserTunnel(limit: Int) async throws -> Bool {
        var processed = 0
        for tunnel in pendingBrowserTunnelRevocations {
            // Persisted entries have no tokens. Retry them only while their
            // owner scope and team are active; account-switch entries with
            // captured credentials remain safe to revoke immediately.
            guard tunnel.credentials != nil
                || (
                    scope == tunnel.scope
                        && scopeTeamID == normalizedTeamID(tunnel.teamID)
                )
            else {
                continue
            }
            guard processed < limit else {
                return true
            }
            processed += 1
            var lastError: (any Error)?
            for _ in 0..<cleanupRetryCount {
                do {
                    try await revokeBrowserTunnel(tunnel)
                    removePendingBrowserTunnelRevocation(tunnel)
                    await clearPersistedBrowserTunnelRevocation(tunnel)
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if let lastError {
                clearPendingBrowserTunnelRevocationCredentials(tunnel)
                await persistPendingBrowserTunnelRevocation(tunnel)
                throw lastError
            }
        }
        return hasEligiblePendingBrowserTunnelRevocation
    }

    private var hasEligiblePendingBrowserTunnelRevocation: Bool {
        pendingBrowserTunnelRevocations.contains {
            $0.credentials != nil
                || (
                    scope == $0.scope
                        && scopeTeamID == normalizedTeamID($0.teamID)
                )
        }
    }

    private func revokeForServerTeardown(
        _ tunnel: (
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        ),
        fallbackCredentials: CloudAPITokenSource.TokenContext,
        attempts: Int
    ) async {
        let credentials = tunnel.credentials ?? CloudAPITokenSource.TokenContext(
            accessToken: fallbackCredentials.accessToken,
            refreshToken: fallbackCredentials.refreshToken,
            teamID: tunnel.teamID
        )
        for _ in 0..<attempts {
            do {
                try await revocationWorker.revoke(
                    deviceFingerprint: tunnel.deviceFingerprint,
                    credentials: credentials
                )
                removePendingBrowserTunnelRevocation(tunnel)
                if browserTunnel?.scope == tunnel.scope,
                   browserTunnel?.deviceFingerprint == tunnel.deviceFingerprint,
                   normalizedTeamID(browserTunnel?.teamID)
                       == normalizedTeamID(tunnel.teamID) {
                    browserTunnel = nil
                }
                await clearPersistedBrowserTunnelRevocation(tunnel)
                return
            } catch {
                continue
            }
        }
        clearPendingBrowserTunnelRevocationCredentials(tunnel)
        if browserTunnel?.scope == tunnel.scope,
           browserTunnel?.deviceFingerprint == tunnel.deviceFingerprint,
           normalizedTeamID(browserTunnel?.teamID)
               == normalizedTeamID(tunnel.teamID) {
            browserTunnel = (
                scope: tunnel.scope,
                deviceFingerprint: tunnel.deviceFingerprint,
                teamID: tunnel.teamID,
                credentials: nil
            )
        }
        await persistPendingBrowserTunnelRevocation(tunnel)
    }

    private func revokeServerTunnelsSerially(
        _ tunnels: [(
            scope: String,
            deviceFingerprint: String,
            teamID: String?,
            credentials: CloudAPITokenSource.TokenContext?
        )],
        expectedScope: String?,
        expectedBrowserTunnelGeneration: UInt64?,
        fallbackCredentials: CloudAPITokenSource.TokenContext,
        attempts: Int
    ) async {
        let operation = operationGate.start { [self] in
            if let expectedBrowserTunnelGeneration,
               browserTunnelGeneration != expectedBrowserTunnelGeneration,
               browserTunnel?.scope == expectedScope {
                return
            }
            for tunnel in tunnels {
                await revokeForServerTeardown(
                    tunnel,
                    fallbackCredentials: fallbackCredentials,
                    attempts: attempts
                )
            }
        }
        do {
            try await CloudSystemVPNTaskTimeout(
                timeout: max(operationTimeout, .seconds(1))
            ).value(operation.result)
        } catch {
            operation.cancelIfPending()
            for tunnel in tunnels {
                await rememberAndPersistPendingBrowserTunnelRevocation(tunnel)
            }
        }
    }

    private func revokeEnrollmentIfOwned(
        _ enrollment: CloudTunnelEnrollment,
        scope: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    ) async {
        guard enrollment.created || enrollment.rotated else { return }
        let tunnel = (
            scope: scope,
            deviceFingerprint: enrollment.deviceFingerprint,
            teamID: credentials?.teamID ?? teamID,
            credentials: credentials
        )
        rememberPendingBrowserTunnelRevocation(tunnel)
        await persistPendingBrowserTunnelRevocation(tunnel)
        guard let credentials else {
            return
        }
        let worker = revocationWorker
        let revoked = await Task.detached(priority: .utility) {
            do {
                try await worker.revoke(
                    deviceFingerprint: enrollment.deviceFingerprint,
                    credentials: credentials
                )
                return true
            } catch {
                return false
            }
        }.value
        if !revoked {
            clearPendingBrowserTunnelRevocationCredentials(tunnel)
        }
        if revoked {
            removePendingBrowserTunnelRevocation(tunnel)
            await clearPersistedBrowserTunnelRevocation(tunnel)
        }
    }

    private func revokeBrowserTunnel(_ tunnel: (
        scope: String,
        deviceFingerprint: String,
        teamID: String?,
        credentials: CloudAPITokenSource.TokenContext?
    )) async throws {
        try await revocationWorker.revoke(
            deviceFingerprint: tunnel.deviceFingerprint,
            credentials: tunnel.credentials
        )
    }

    private func retryPendingCleanup() {
        guard manager.isAvailable,
              cleanupPending || !pendingBrowserTunnelRevocations.isEmpty
        else { return }
        publish(.disconnecting)
        guard !operationGate.hasPendingOperation else {
            scheduleCleanupRetry()
            return
        }
        let requestedTeamID = scopeTeamID
        enqueue { [self] generation in
            do {
                if !pendingBrowserTunnelRevocations.isEmpty {
                    let hasDeferredCleanup = try await revokePendingBrowserTunnel(
                        limit: maxPendingRevocationsPerRetry
                    )
                    if hasDeferredCleanup {
                        scheduleCleanupRetry()
                    }
                    guard self.isCurrent(generation) else { return }
                    browserTunnel = nil
                }
                if cleanupPending {
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                }
                if let scope {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: scope, teamID: requestedTeamID)
                    }
                    guard self.isCurrent(generation) else { return }
                    needsPlatformReconciliation = false
                }
                accept(manager.phase)
            } catch {
                guard self.isCurrent(generation) else { return }
                publish(.failed(.configuration))
            }
        }
    }

    private func scheduleCleanupRetry() {
        cleanupRetryRequested = true
        guard cleanupRetryTask == nil else { return }
        cleanupRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForCleanupRetryPrerequisites() else {
                self.cleanupRetryTask = nil
                self.cleanupRetryRequested = false
                guard self.cleanupPending || !self.pendingBrowserTunnelRevocations.isEmpty else {
                    return
                }
                self.publish(.failed(.configuration))
                return
            }
            guard self.cleanupPending || !self.pendingBrowserTunnelRevocations.isEmpty,
                  self.cleanupRetryRequested else { return }
            self.cleanupRetryTask = nil
            self.cleanupRetryRequested = false
            self.retryPendingCleanup()
        }
    }

    private func waitForCleanupRetryPrerequisites() async -> Bool {
        if let operation {
            await operation.value
        }
        return await waitForOperationGate()
    }

    private func scheduleEnableRetry() {
        enableRetryRequested = true
        guard enableRetryTask == nil else { return }
        enableRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForOperationGate() else {
                self.enableRetryTask = nil
                self.enableRetryRequested = false
                guard self.scope != nil else { return }
                self.publish(.failed(.configuration))
                return
            }
            guard self.scope != nil, self.enableRetryRequested else { return }
            self.enableRetryTask = nil
            self.enableRetryRequested = false
            guard !self.operationGate.hasPendingOperation else {
                self.scheduleEnableRetry()
                return
            }
            if !self.needsPlatformReconciliation,
               self.manager.phase.isRequestedOn {
                self.accept(self.manager.phase)
                return
            }
            self.publish(.off)
            self.enable()
        }
    }

    private func performBounded<T: Sendable>(
        reconcilePlatformOnTimeout: Bool = false,
        reconcileCleanupOnTimeout: Bool = false,
        retainPendingOperationOnTimeout: Bool = false,
        onTimeout: @escaping @MainActor () -> Void = {},
        _ action: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let operation = operationGate.start(action)
        let completion = Task { @MainActor in
            await operation.acquired.value
            return try await operation.result.value
        }
        do {
            return try await timeout.value(completion)
        } catch {
            let timedOut = error is CloudSystemVPNTaskTimeout.Failure
            if timedOut {
                onTimeout()
            }
            if timedOut, reconcilePlatformOnTimeout || reconcileCleanupOnTimeout {
                needsPlatformReconciliation = true
            }
            if reconcilePlatformOnTimeout, error is CloudSystemVPNTaskTimeout.Failure {
                watchPlatformCompletion(operation.result)
            }
            if reconcileCleanupOnTimeout, error is CloudSystemVPNTaskTimeout.Failure {
                watchCleanupCompletion(operation.result)
            }
            if timedOut {
                let grace = operationTimeout + operationTimeout + operationTimeout
                let abandoned = operation.abandonIfAcquired(after: grace) { [weak self] in
                    self?.manager.cancelPendingOperation()
                }
                if !abandoned && !retainPendingOperationOnTimeout {
                    operation.cancelIfPending()
                }
            } else if !retainPendingOperationOnTimeout {
                operation.cancelIfPending()
            }
            throw error
        }
    }

    private func watchPlatformCompletion<T: Sendable>(
        _ completion: Task<T, any Error>
    ) {
        Task { @MainActor [weak self] in
            let result = await completion.result
            guard let self else { return }
            await self.operationGate.waitForIdle()
            guard self.scope != nil,
                  self.operation == nil,
                  !self.operationGate.hasPendingOperation else { return }
            guard case .success = result else { return }
            self.needsPlatformReconciliation = false
            self.accept(self.manager.phase)
        }
    }

    private func watchCleanupCompletion<T: Sendable>(
        _ completion: Task<T, any Error>
    ) {
        Task { @MainActor [weak self] in
            let result = await completion.result
            guard let self else { return }
            await self.operationGate.waitForIdle()
            guard self.operation == nil,
                  !self.operationGate.hasPendingOperation else { return }
            switch result {
            case .success:
                self.cleanupPending = false
                if self.scope == nil {
                    self.needsPlatformReconciliation = false
                    self.publish(self.manager.phase)
                } else {
                    await self.refresh()
                }
            case .failure:
                self.publish(.failed(.configuration))
            }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func normalizedTeamID(_ teamID: String?) -> String? {
        guard let teamID else { return nil }
        let normalized = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    @MainActor
    private final class EnableAttempt {
        private(set) var isValid = true

        func invalidate() {
            isValid = false
        }
    }

    private func enqueue(_ action: @escaping @MainActor (UInt64) async -> Void) {
        operation?.cancel()
        generation &+= 1
        let generation = generation
        operation = Task { [weak self] in
            guard let self, self.generation == generation else { return }
            await action(generation)
            if self.generation == generation { self.operation = nil }
        }
    }
}
