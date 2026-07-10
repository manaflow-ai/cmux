public import CMUXMobileCore
import Foundation

/// Owns Iroh endpoint generations and recreates unexpectedly stopped drivers.
///
/// The actor preserves the injected secret key across foreground recreation,
/// rejects stale async bind results with a lifecycle revision, and exposes
/// non-sensitive state through ``events()``.
public actor CmxIrohEndpointSupervisor {
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
        let candidateConfiguration = try CmxIrohEndpointConfiguration(
            secretKey: configuration.secretKey,
            alpns: configuration.alpns,
            bindPolicy: configuration.bindPolicy,
            managedRelayURLs: configuration.managedRelayURLs,
            relays: relays
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
        try await endpoint.replaceRelays(relays)
        guard lifecycleRevision == revision, snapshot.state == .active else {
            throw CmxIrohEndpointSupervisorError.superseded
        }
        configuration = candidateConfiguration
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
            break
        case .networkChanged:
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

    private func publish(_ event: CmxIrohEndpointSupervisorEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
