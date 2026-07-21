public import CMUXMobileCore
import Foundation

/// Owns Iroh endpoint generations and recreates unexpectedly stopped drivers.
///
/// The actor preserves the injected secret key across foreground recreation,
/// rejects stale async bind results with a lifecycle revision, and exposes
/// non-sensitive state through ``events()``.
public actor CmxIrohEndpointSupervisor {
    private struct RelayReadinessWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let factory: any CmxIrohEndpointFactory
    private var configuration: CmxIrohEndpointConfiguration
    private var endpoint: (any CmxIrohEndpoint)?
    private var bindingOperation: (
        revision: UInt64,
        generation: UInt64,
        task: Task<any CmxIrohEndpoint, any Error>
    )?
    private var healthTask: Task<Void, Never>?
    private var runtimeGeneration: UInt64 = 0
    private var lifecycleRevision: UInt64 = 0
    private var desiredActive = false
    private var snapshot = CmxIrohEndpointSnapshot(
        runtimeGeneration: 0,
        state: .inactive,
        identity: nil
    )
    private var observers: [UUID: AsyncStream<CmxIrohEndpointSupervisorEvent>.Continuation] = [:]
    /// The exact active generation for which native Iroh reported a usable
    /// home relay, or whose public address already contains a usable relay
    /// hint. No relay URL or credential leaves this actor through this state.
    private var relayReadyGeneration: UInt64?
    private var relayReadinessWaiters: [UUID: RelayReadinessWaiter] = [:]

    /// Creates an inactive endpoint supervisor.
    ///
    /// - Parameters:
    ///   - factory: The concrete Iroh binding seam.
    ///   - configuration: The stable key, ALPN, relay allowlist, and current tokens.
    public init(
        factory: any CmxIrohEndpointFactory,
        configuration: CmxIrohEndpointConfiguration
    ) {
        self.factory = factory
        self.configuration = configuration
    }

    /// Returns an event stream beginning with the current lifecycle snapshot.
    ///
    /// - Returns: A stream that finishes when its consumer cancels observation.
    public func events() -> AsyncStream<CmxIrohEndpointSupervisorEvent> {
        let observerID = UUID()
        let initialSnapshot = snapshot
        return AsyncStream { continuation in
            observers[observerID] = continuation
            continuation.yield(.snapshot(initialSnapshot))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    /// Binds an endpoint if the lifecycle is not already active.
    ///
    /// - Returns: The active generation snapshot.
    /// - Throws: A bind error, `CancellationError`, or
    ///   ``CmxIrohEndpointSupervisorError/superseded``.
    @discardableResult
    public func activate() async throws -> CmxIrohEndpointSnapshot {
        try Task.checkCancellation()
        desiredActive = true
        if endpoint != nil, snapshot.state == .active {
            return snapshot
        }

        let operation: (
            revision: UInt64,
            generation: UInt64,
            task: Task<any CmxIrohEndpoint, any Error>
        )
        if let bindingOperation {
            operation = bindingOperation
        } else {
            lifecycleRevision &+= 1
            runtimeGeneration &+= 1
            invalidateRelayReadiness(
                error: CmxIrohEndpointSupervisorError.superseded
            )
            let revision = lifecycleRevision
            let generation = runtimeGeneration
            let factory = factory
            let configuration = configuration
            let task = Task<any CmxIrohEndpoint, any Error> {
                let candidate = try await factory.bind(configuration: configuration)
                guard !Task.isCancelled else {
                    await candidate.close()
                    throw CancellationError()
                }
                return candidate
            }
            operation = (revision, generation, task)
            bindingOperation = operation
            publishSnapshot(
                CmxIrohEndpointSnapshot(
                    runtimeGeneration: generation,
                    state: .starting,
                    identity: nil
                )
            )
        }

        do {
            let candidate = try await operation.task.value
            if endpoint != nil,
               snapshot.state == .active,
               snapshot.runtimeGeneration == operation.generation {
                return snapshot
            }
            guard desiredActive, lifecycleRevision == operation.revision else {
                await candidate.close()
                throw CmxIrohEndpointSupervisorError.superseded
            }
            let identity = await candidate.identity()
            guard desiredActive, lifecycleRevision == operation.revision else {
                await candidate.close()
                throw CmxIrohEndpointSupervisorError.superseded
            }
            endpoint = candidate
            bindingOperation = nil
            publishSnapshot(
                CmxIrohEndpointSnapshot(
                    runtimeGeneration: operation.generation,
                    state: .active,
                    identity: identity
                )
            )
            observeHealth(of: candidate, generation: operation.generation)
            return snapshot
        } catch {
            if bindingOperation?.revision == operation.revision {
                bindingOperation = nil
            }
            if lifecycleRevision == operation.revision, endpoint == nil {
                publishSnapshot(
                    CmxIrohEndpointSnapshot(
                        runtimeGeneration: operation.generation,
                        state: desiredActive ? .failed : .inactive,
                        identity: nil
                    )
                )
            }
            throw error
        }
    }

    /// Closes the active endpoint and invalidates all generation-owned work.
    public func deactivate() async {
        desiredActive = false
        lifecycleRevision &+= 1
        invalidateRelayReadiness(error: CmxIrohEndpointSupervisorError.inactive)
        bindingOperation?.task.cancel()
        bindingOperation = nil
        healthTask?.cancel()
        healthTask = nil
        let closingEndpoint = endpoint
        endpoint = nil
        publishSnapshot(
            CmxIrohEndpointSnapshot(
                runtimeGeneration: runtimeGeneration,
                state: .inactive,
                identity: nil
            )
        )
        await closingEndpoint?.close()
    }

    /// Returns the active endpoint for a generation-scoped operation.
    ///
    /// - Returns: The active endpoint existential.
    /// - Throws: ``CmxIrohEndpointSupervisorError/inactive`` when unbound.
    public func activeEndpoint() throws -> any CmxIrohEndpoint {
        guard let endpoint, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.inactive
        }
        return endpoint
    }

    /// Returns whether the active endpoint has a credential-free usable home
    /// relay signal for its current generation.
    ///
    /// The native `online` signal is authoritative. A current public relay hint
    /// is also sufficient because it can only be produced from the active
    /// endpoint's exact relay allowlist.
    public func hasUsableHomeRelay() async -> Bool {
        guard let endpoint, snapshot.state == .active else { return false }
        let generation = snapshot.runtimeGeneration
        if relayReadyGeneration == generation { return true }
        guard await Self.hasUsableRelayHint(endpoint) else { return false }
        markRelayReady(generation: generation)
        return true
    }

    /// Returns whether the active generation owns at least one configured
    /// relay. This exposes no URL or credential material.
    func hasConfiguredRelay() -> Bool {
        endpoint != nil
            && snapshot.state == .active
            && !configuration.relayProfile.activeRelays.isEmpty
    }

    /// Waits for native Iroh to establish a usable home relay without polling.
    ///
    /// The wait is scoped to the current endpoint generation, races a health
    /// signal against one cancellable deadline, and fails if lifecycle changes
    /// replace the endpoint while the caller is suspended.
    public func waitForUsableHomeRelay(
        timeout: Duration = .seconds(15)
    ) async throws {
        guard timeout > .zero,
              endpoint != nil,
              snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.inactive
        }
        let generation = snapshot.runtimeGeneration
        if await hasUsableHomeRelay() { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw CmxIrohEndpointSupervisorError.inactive
                }
                try await self.awaitRelayReadiness(generation: generation)
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw CmxIrohEndpointSupervisorError.relayReadinessTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CmxIrohEndpointSupervisorError.inactive
            }
            _ = result
        }

        try Task.checkCancellation()
        guard snapshot.state == .active,
              snapshot.runtimeGeneration == generation,
              relayReadyGeneration == generation else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
    }

    /// Verifies the live driver after app suspension and recreates it when stale.
    ///
    /// Healthy generations remain untouched, preserving every open QUIC
    /// connection and stream across ordinary background transitions.
    ///
    /// - Returns: The current or replacement active generation snapshot.
    /// - Throws: The replacement bind error when the stale generation cannot recover.
    @discardableResult
    public func ensureHealthy() async throws -> CmxIrohEndpointSnapshot {
        guard desiredActive else {
            throw CmxIrohEndpointSupervisorError.inactive
        }
        if let endpoint, snapshot.state == .active, await endpoint.isHealthy() {
            return snapshot
        }

        lifecycleRevision &+= 1
        invalidateRelayReadiness(
            error: CmxIrohEndpointSupervisorError.superseded
        )
        bindingOperation?.task.cancel()
        bindingOperation = nil
        healthTask?.cancel()
        healthTask = nil
        let staleEndpoint = endpoint
        self.endpoint = nil
        await staleEndpoint?.close()
        return try await activate()
    }

    /// Installs a fresh relay set on the live endpoint before committing it for future binds.
    ///
    /// The concrete endpoint must add replacement credentials before removing
    /// stale credentials. A failed update leaves this supervisor's last-known
    /// good configuration unchanged.
    ///
    /// - Parameter relays: The complete new relay credential set.
    /// - Throws: A fleet validation or endpoint update error.
    public func replaceRelays(_ relays: [CmxIrohRelayConfiguration]) async throws {
        try await replaceRelays(
            relays,
            expectedIdentity: Optional<CmxIrohPeerIdentity>.none
        )
    }

    /// Installs relay credentials only on the active endpoint identity that requested them.
    ///
    /// A lifecycle transition during the update leaves the next generation's
    /// configuration unchanged. This prevents a delayed token response for an
    /// old binding from being committed to a replacement endpoint.
    public func replaceRelays(
        _ relays: [CmxIrohRelayConfiguration],
        expectedIdentity: CmxIrohPeerIdentity
    ) async throws {
        try await replaceRelays(relays, expectedIdentity: Optional(expectedIdentity))
    }

    private func replaceRelays(
        _ relays: [CmxIrohRelayConfiguration],
        expectedIdentity: CmxIrohPeerIdentity?
    ) async throws {
        let candidateProfile = try configuration.relayProfile.replacingManagedRelays(relays)
        let candidateConfiguration = CmxIrohEndpointConfiguration(
            secretKey: configuration.secretKey,
            alpns: configuration.alpns,
            bindPolicy: configuration.bindPolicy,
            relayProfile: candidateProfile
        )
        guard let endpoint else {
            guard expectedIdentity == nil else {
                throw CmxIrohEndpointSupervisorError.inactive
            }
            configuration = candidateConfiguration
            return
        }
        let revision = lifecycleRevision
        if let expectedIdentity {
            let actualIdentity = await endpoint.identity()
            guard lifecycleRevision == revision,
                  snapshot.state == .active,
                  actualIdentity == expectedIdentity else {
                throw CmxIrohEndpointSupervisorError.superseded
            }
        }
        let previousAddress = await endpoint.address()
        guard lifecycleRevision == revision, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
        let priorRelayReadyGeneration = relayReadyGeneration
        relayReadyGeneration = nil
        do {
            try await endpoint.replaceRelays(relays)
        } catch {
            if lifecycleRevision == revision,
               snapshot.state == .active,
               priorRelayReadyGeneration == snapshot.runtimeGeneration {
                markRelayReady(generation: snapshot.runtimeGeneration)
            }
            throw error
        }
        let updatedAddress = await endpoint.address()
        guard lifecycleRevision == revision, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
        configuration = candidateConfiguration
        if Self.hasUsableRelayHint(updatedAddress) {
            markRelayReady(generation: snapshot.runtimeGeneration)
        }
        // The endpoint's address watcher may observe the new home relay while
        // `replaceRelays` is suspended, before the endpoint commits the matching
        // allowlist. That early event is filtered by the old profile and may be
        // the only native address callback. Republish after both endpoint and
        // supervisor configuration commit so owners re-read one coherent route.
        if updatedAddress != previousAddress {
            publish(.networkChanged(runtimeGeneration: snapshot.runtimeGeneration))
        }
    }

    /// Installs a complete managed selection or custom relay override live.
    ///
    /// The endpoint keeps its stable key and adds replacement relays before it
    /// removes stale relays. A failed update leaves the supervisor's future bind
    /// configuration unchanged.
    ///
    /// - Parameter profile: Exact relay allowlist and active configurations.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile
    ) async throws {
        try await replaceRelayProfile(
            profile,
            expectedIdentity: Optional<CmxIrohPeerIdentity>.none
        )
    }

    /// Installs a profile only on the active endpoint identity that requested it.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        expectedIdentity: CmxIrohPeerIdentity
    ) async throws {
        try await replaceRelayProfile(profile, expectedIdentity: Optional(expectedIdentity))
    }

    private func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        expectedIdentity: CmxIrohPeerIdentity?
    ) async throws {
        let candidateConfiguration = CmxIrohEndpointConfiguration(
            secretKey: configuration.secretKey,
            alpns: configuration.alpns,
            bindPolicy: configuration.bindPolicy,
            relayProfile: profile
        )
        guard let endpoint else {
            guard expectedIdentity == nil else {
                throw CmxIrohEndpointSupervisorError.inactive
            }
            configuration = candidateConfiguration
            return
        }
        let revision = lifecycleRevision
        if let expectedIdentity {
            let actualIdentity = await endpoint.identity()
            guard lifecycleRevision == revision,
                  snapshot.state == .active,
                  actualIdentity == expectedIdentity else {
                throw CmxIrohEndpointSupervisorError.superseded
            }
        }
        let previousAddress = await endpoint.address()
        guard lifecycleRevision == revision, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
        let priorRelayReadyGeneration = relayReadyGeneration
        relayReadyGeneration = nil
        do {
            try await endpoint.replaceRelayProfile(profile)
        } catch {
            if lifecycleRevision == revision,
               snapshot.state == .active,
               priorRelayReadyGeneration == snapshot.runtimeGeneration {
                markRelayReady(generation: snapshot.runtimeGeneration)
            }
            throw error
        }
        let updatedAddress = await endpoint.address()
        guard lifecycleRevision == revision, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
        configuration = candidateConfiguration
        if Self.hasUsableRelayHint(updatedAddress) {
            markRelayReady(generation: snapshot.runtimeGeneration)
        }
        if updatedAddress != previousAddress {
            publish(.networkChanged(runtimeGeneration: snapshot.runtimeGeneration))
        }
    }

    private func observeHealth(
        of endpoint: any CmxIrohEndpoint,
        generation: UInt64
    ) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let events = await endpoint.healthEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleHealthEvent(event, generation: generation)
            }
        }
    }

    private func handleHealthEvent(
        _ event: CmxIrohEndpointHealthEvent,
        generation: UInt64
    ) async {
        guard desiredActive,
              generation == runtimeGeneration,
              snapshot.state == .active else {
            return
        }
        switch event {
        case .online:
            markRelayReady(generation: generation)
            // Initial discovery can finish before or after the runtime registers.
            // Treat online as a reachability change so the broker receives the
            // endpoint's first usable relay or direct-address hints.
            publish(.networkChanged(runtimeGeneration: generation))
        case .networkChanged:
            if let endpoint,
               await Self.hasUsableRelayHint(endpoint) {
                markRelayReady(generation: generation)
            }
            publish(.networkChanged(runtimeGeneration: generation))
        case .closedUnexpectedly:
            let previousGeneration = generation
            endpoint = nil
            healthTask = nil
            do {
                let recovered = try await activate()
                publish(
                    .recovered(
                        previousGeneration: previousGeneration,
                        newGeneration: recovered.runtimeGeneration
                    )
                )
            } catch {
                // `activate()` publishes the failed snapshot. The next explicit
                // lifecycle activation can retry without reusing stale handles.
            }
        }
    }

    private func publishSnapshot(_ newSnapshot: CmxIrohEndpointSnapshot) {
        snapshot = newSnapshot
        publish(.snapshot(newSnapshot))
    }

    private func awaitRelayReadiness(generation: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard snapshot.state == .active,
                      snapshot.runtimeGeneration == generation else {
                    continuation.resume(
                        throwing: CmxIrohEndpointSupervisorError.superseded
                    )
                    return
                }
                if relayReadyGeneration == generation {
                    continuation.resume()
                } else {
                    relayReadinessWaiters[id] = RelayReadinessWaiter(
                        generation: generation,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRelayReadinessWaiter(id: id) }
        }
    }

    private func cancelRelayReadinessWaiter(id: UUID) {
        relayReadinessWaiters.removeValue(forKey: id)?
            .continuation.resume(throwing: CancellationError())
    }

    private func markRelayReady(generation: UInt64) {
        guard generation > 0,
              snapshot.state == .active,
              snapshot.runtimeGeneration == generation else { return }
        relayReadyGeneration = generation
        let ready = relayReadinessWaiters.filter { $0.value.generation == generation }
        for (id, waiter) in ready {
            relayReadinessWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func invalidateRelayReadiness(error: any Error) {
        relayReadyGeneration = nil
        let waiters = relayReadinessWaiters.values
        relayReadinessWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private static func hasUsableRelayHint(
        _ endpoint: any CmxIrohEndpoint
    ) async -> Bool {
        hasUsableRelayHint(await endpoint.address())
    }

    private static func hasUsableRelayHint(
        _ address: CmxIrohEndpointAddress
    ) -> Bool {
        let current = Date()
        return address.pathHints.contains {
            $0.kind == .relayURL && $0.isUsable(at: current)
        }
    }

    private func publish(_ event: CmxIrohEndpointSupervisorEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
