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
    private let operationTimeout: Duration
    private let operationGate = CloudSystemVPNOperationGate()
    private let cleanupRetryCount: Int
    private var scope: String?
    private var hasLoadedScope = false
    private var cleanupPending = false
    private var pendingTunnelRevocation: (deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose)?
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
    public init(
        service: any CloudVMServing,
        identityStore: any CloudDeviceIdentityStoring,
        manager: any CloudSystemVPNManaging,
        deviceName: String,
        operationTimeout: Duration = .seconds(30),
        cleanupRetryCount: Int = 3
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.manager = manager
        self.deviceName = deviceName
        let boundedTimeout = max(.milliseconds(1), operationTimeout)
        timeout = CloudSystemVPNTaskTimeout(timeout: boundedTimeout)
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
    public func setScope(_ newScope: String?) {
        guard !hasLoadedScope || scope != newScope || cleanupPending else { return }
        hasLoadedScope = true
        enableRetryRequested = false
        enableRetryTask?.cancel()
        enableRetryTask = nil
        cleanupRetryRequested = false
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        let previousScope = scope
        scope = newScope
        // A device that cannot run the VPN never saved one, so there is
        // nothing to load or remove.
        guard manager.isAvailable else {
            cleanupPending = false
            return
        }
        let removesExistingConfiguration =
            previousScope != nil || newScope == nil || cleanupPending
        cleanupPending = removesExistingConfiguration
        enqueue { [self] generation in
            do {
                if removesExistingConfiguration {
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                }
                if let newScope {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: newScope)
                    }
                    guard self.isCurrent(generation) else { return }
                    needsPlatformReconciliation = false
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
            guard cleanupPending else { return }
            enqueue { [self] generation in
                do {
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
            do {
                if cleanupPending {
                    try await removeConfigurationWithRetry()
                    guard self.isCurrent(generation) else { return }
                    cleanupPending = false
                }
                try await performBounded(reconcilePlatformOnTimeout: true) {
                    try await self.manager.refresh(scope: scope)
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
        guard !cleanupPending else {
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
        let shouldReconcile = needsPlatformReconciliation
        publish(.preparing)
        enqueue { [self] generation in
            do {
                if shouldReconcile {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: scope)
                    }
                    guard self.isCurrent(generation), self.scope == scope else {
                        throw CancellationError()
                    }
                    needsPlatformReconciliation = false
                    if manager.phase.isRequestedOn {
                        publish(manager.phase)
                        return
                    }
                }
                let keyPair = WireGuardKeyPair()
                try await performBounded(reconcilePlatformOnTimeout: true) {
                    if let pending = self.pendingTunnelRevocation {
                        try await self.service.revokeTunnel(
                            deviceFingerprint: pending.deviceFingerprint,
                            tunnelPurpose: pending.tunnelPurpose
                        )
                        self.pendingTunnelRevocation = nil
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
                            deviceName: self.deviceName
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw CloudSystemVPNError.enrollment
                    }
                    guard self.isCurrent(generation), self.scope == scope else {
                        throw CancellationError()
                    }
                    try await self.install(enrollment: enrollment, privateKey: keyPair.privateKey, scope: scope)
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
        scope: String
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
            try await manager.installAndStart(configuration: configuration.text, scope: scope)
        } catch {
            guard enrollment.created else { throw error }
            do {
                try await service.revokeTunnel(
                    deviceFingerprint: enrollment.deviceFingerprint,
                    tunnelPurpose: .browser
                )
            } catch {
                pendingTunnelRevocation = (
                    deviceFingerprint: enrollment.deviceFingerprint,
                    tunnelPurpose: .browser
                )
                throw CloudSystemVPNError.configuration
            }
            throw error
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
        if cleanupPending {
            retryPendingCleanup()
        } else {
            enable()
        }
    }

    /// Waits for queued saves and removals. Operations run one at a time,
    /// including while the iOS consent prompt is open.
    public func waitForPendingOperation() async { await operation?.value }

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

    private func retryPendingCleanup() {
        guard manager.isAvailable, cleanupPending else { return }
        publish(.disconnecting)
        guard !operationGate.hasPendingOperation else {
            scheduleCleanupRetry()
            return
        }
        enqueue { [self] generation in
            do {
                try await removeConfigurationWithRetry()
                guard self.isCurrent(generation) else { return }
                cleanupPending = false
                if let scope {
                    try await performBounded(reconcilePlatformOnTimeout: true) {
                        try await self.manager.refresh(scope: scope)
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
            await self.operationGate.waitForIdle()
            guard self.cleanupPending,
                  self.cleanupRetryRequested else { return }
            self.cleanupRetryTask = nil
            self.cleanupRetryRequested = false
            self.retryPendingCleanup()
        }
    }

    private func scheduleEnableRetry() {
        enableRetryRequested = true
        guard enableRetryTask == nil else { return }
        enableRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.operationGate.waitForIdle()
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
            if timedOut, reconcilePlatformOnTimeout || reconcileCleanupOnTimeout {
                needsPlatformReconciliation = true
            }
            if reconcilePlatformOnTimeout, error is CloudSystemVPNTaskTimeout.Failure {
                watchPlatformCompletion(completion)
            }
            if reconcileCleanupOnTimeout, error is CloudSystemVPNTaskTimeout.Failure {
                watchCleanupCompletion(completion)
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
            _ = await completion.result
            guard let self else { return }
            await self.operationGate.waitForIdle()
            guard self.scope != nil,
                  !self.needsPlatformReconciliation,
                  self.operation == nil,
                  !self.operationGate.hasPendingOperation else { return }
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
