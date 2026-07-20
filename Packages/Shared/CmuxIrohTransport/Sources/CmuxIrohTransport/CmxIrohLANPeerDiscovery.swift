public import CMUXMobileCore
public import Foundation

public enum CmxIrohLANPeerDiscoveryOutcome: Equatable, Sendable {
    case found([CmxIrohLANResolvedPeer])
    case notFound
    case policyDenied
}

private actor CmxIrohLANChangeSignal {
    private var generation: UInt64 = 0
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    func snapshot() -> UInt64 { generation }

    func events(after expectedGeneration: UInt64) -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard generation == expectedGeneration else {
                continuation.yield(())
                continuation.finish()
                return
            }
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish() {
        generation &+= 1
        for observer in observers.values { observer.yield(()) }
    }

    private func remove(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// Lazily browses for an already-known peer and owns generation-scoped profiles.
public actor CmxIrohLANPeerDiscovery {
    public typealias BrowserFactory = @Sendable () -> any CmxIrohBonjourBrowsing
    public typealias NetworkPathProvider = @Sendable () async -> CmxIrohNetworkPathSnapshot
    public typealias ProfileAuthorizer = @Sendable (
        _ profile: CmxIrohNetworkProfileKey,
        _ pathGeneration: UInt64,
        _ interfaceIndex: UInt32
    ) async -> Bool
    public typealias ProfileRevoker = @Sendable (
        _ profile: CmxIrohNetworkProfileKey,
        _ pathGeneration: UInt64
    ) async -> Void

    private struct RequestKey: Hashable, Sendable {
        let deviceID: String
        let endpointID: CmxIrohPeerIdentity
    }

    private struct RequestContext: Sendable {
        let rendezvous: CmxIrohLANRendezvous
        let bindings: [CmxIrohBrokerBindingMetadata]
        let expectedDeviceID: String
        let expectedEndpointID: CmxIrohPeerIdentity
        let pathGeneration: UInt64
    }

    private struct ProfileGeneration: Hashable, Sendable {
        let profile: CmxIrohNetworkProfileKey
        let generation: UInt64
    }

    private let browserFactory: BrowserFactory
    private let interfaces: any CmxIrohLANInterfaceSnapshotProviding
    private let resolver: CmxIrohLANDiscoveryResolver
    private let clock: any CmxIrohLANClock
    private let networkPath: NetworkPathProvider
    private let authorizeProfile: ProfileAuthorizer
    private let revokeProfile: ProfileRevoker
    private let changeSignal = CmxIrohLANChangeSignal()
    private var browser: (any CmxIrohBonjourBrowsing)?
    private var browserTask: Task<Void, Never>?
    private var requests: [RequestKey: RequestContext] = [:]
    private var services: [CmxIrohBonjourServiceID: CmxIrohBonjourResolvedService] = [:]
    private var results: [RequestKey: [CmxIrohBonjourServiceID: CmxIrohLANResolvedPeer]] = [:]
    private var permissionDenied = false
    private var lifecycleRevision: UInt64 = 0

    public init(
        browserFactory: @escaping BrowserFactory = { CmxIrohSystemBonjourBrowser() },
        interfaces: any CmxIrohLANInterfaceSnapshotProviding = CmxIrohSystemLANInterfaceSnapshotProvider(),
        resolver: CmxIrohLANDiscoveryResolver = CmxIrohLANDiscoveryResolver(),
        clock: any CmxIrohLANClock = CmxIrohLANSystemClock(),
        networkPath: @escaping NetworkPathProvider,
        authorizeProfile: @escaping ProfileAuthorizer,
        revokeProfile: @escaping ProfileRevoker
    ) {
        self.browserFactory = browserFactory
        self.interfaces = interfaces
        self.resolver = resolver
        self.clock = clock
        self.networkPath = networkPath
        self.authorizeProfile = authorizeProfile
        self.revokeProfile = revokeProfile
    }

    /// Browses only after a reconnect for one cached, already-known Mac.
    public func discover(
        rendezvous: CmxIrohLANRendezvous,
        authenticatedBindings: [CmxIrohBrokerBindingMetadata],
        expectedMacDeviceID: String,
        expectedEndpointID: CmxIrohPeerIdentity,
        timeout: TimeInterval = 0.75
    ) async -> CmxIrohLANPeerDiscoveryOutcome {
        guard authenticatedBindings.count <= CmxIrohDiscoveryResponse.maximumBindingCount else {
            return .notFound
        }
        let path = await networkPath()
        let key = RequestKey(
            deviceID: cmxCanonicalDeviceID(expectedMacDeviceID),
            endpointID: expectedEndpointID
        )
        guard requests[key] != nil || requests.count < 32 else { return .notFound }
        requests[key] = RequestContext(
            rendezvous: rendezvous,
            bindings: authenticatedBindings,
            expectedDeviceID: expectedMacDeviceID,
            expectedEndpointID: expectedEndpointID,
            pathGeneration: path.generation
        )
        await resolveKnownServices(for: key)
        if let outcome = await currentOutcome(for: key) { return outcome }
        guard !permissionDenied else { return .policyDenied }
        let changeGeneration = await changeSignal.snapshot()
        startBrowserIfNeeded()
        guard timeout.isFinite, timeout > 0 else { return .notFound }
        await waitForChangeOrTimeout(timeout, after: changeGeneration)
        if let outcome = await currentOutcome(for: key) { return outcome }
        return permissionDenied ? .policyDenied : .notFound
    }

    /// Invalidates every result before a new path generation can authorize it.
    public func pathDidChange() async {
        lifecycleRevision &+= 1
        await clearResultsAndProfiles()
        requests.removeAll(keepingCapacity: false)
        services.removeAll(keepingCapacity: false)
        permissionDenied = false
        browserTask?.cancel()
        browserTask = nil
        await browser?.stop()
        browser = nil
        await changeSignal.publish()
    }

    /// Allows a later explicit reconnect to retry after Local Network changes.
    ///
    /// Foregrounding never starts Bonjour. It only discards the sticky denial
    /// and stale request state when the previous browser was policy-blocked.
    public func permissionMayHaveChanged() async {
        guard permissionDenied else { return }
        lifecycleRevision &+= 1
        await clearResultsAndProfiles()
        requests.removeAll(keepingCapacity: false)
        services.removeAll(keepingCapacity: false)
        permissionDenied = false
        browserTask?.cancel()
        browserTask = nil
        await browser?.stop()
        browser = nil
        await changeSignal.publish()
    }

    /// Clears account material and browsing on sign-out.
    public func stop() async {
        await pathDidChange()
    }

    private func startBrowserIfNeeded() {
        guard browser == nil else { return }
        let browser = browserFactory()
        self.browser = browser
        let revision = lifecycleRevision
        browserTask = Task { [weak self] in
            let events = await browser.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, revision: revision)
            }
        }
    }

    private func handle(
        _ event: CmxIrohBonjourBrowserEvent,
        revision: UInt64
    ) async {
        guard revision == lifecycleRevision else { return }
        switch event {
        case let .resolved(id, service):
            guard CmxIrohLANRendezvousAliasGenerator.isCanonicalAlias(id.serviceName),
                  services.count < 64 || services[id] != nil else { return }
            services[id] = service
            for key in Array(requests.keys) { await resolve(service, id: id, for: key) }
        case let .removed(id):
            services.removeValue(forKey: id)
            var removedPeers: [CmxIrohLANResolvedPeer] = []
            for key in Array(results.keys) {
                if let removed = results[key]?.removeValue(forKey: id) {
                    removedPeers.append(removed)
                }
                if results[key]?.isEmpty == true { results.removeValue(forKey: key) }
            }
            let used = Set(results.values.flatMap { $0.values.map(\.networkProfile) })
            for peer in removedPeers where !used.contains(peer.networkProfile) {
                await revokeProfile(peer.networkProfile, peer.pathGeneration)
            }
        case .policyDenied:
            permissionDenied = true
            await clearResultsAndProfiles()
            browserTask?.cancel()
            browserTask = nil
            await browser?.stop()
            browser = nil
        case .failed:
            break
        }
        guard revision == lifecycleRevision else { return }
        await changeSignal.publish()
    }

    private func resolveKnownServices(for key: RequestKey) async {
        for (id, service) in Array(services) { await resolve(service, id: id, for: key) }
    }

    private func resolve(
        _ service: CmxIrohBonjourResolvedService,
        id: CmxIrohBonjourServiceID,
        for key: RequestKey
    ) async {
        guard let context = requests[key] else { return }
        let currentPath = await networkPath()
        guard currentPath.generation == context.pathGeneration,
              let currentInterfaces = try? interfaces.interfaceAddresses(),
              let peer = try? resolver.resolve(
                  service,
                  rendezvous: context.rendezvous,
                  authenticatedBindings: context.bindings,
                  expectedMacDeviceID: context.expectedDeviceID,
                  expectedEndpointID: context.expectedEndpointID,
                  networkPathSnapshot: currentPath,
                  interfaces: currentInterfaces,
                  at: clock.now()
              ),
              await authorizeProfile(
                  peer.networkProfile,
                  currentPath.generation,
                  peer.interfaceIndex
              ) else { return }
        let afterAuthorization = await networkPath()
        guard afterAuthorization.generation == currentPath.generation,
              afterAuthorization.activeNetworkProfiles.contains(peer.networkProfile) else {
            await revokeProfile(peer.networkProfile, currentPath.generation)
            return
        }
        results[key, default: [:]][id] = peer
    }

    private func currentOutcome(for key: RequestKey) async -> CmxIrohLANPeerDiscoveryOutcome? {
        guard let peers = results[key]?.values, !peers.isEmpty else { return nil }
        let path = await networkPath()
        let current = peers.filter { peer in
            peer.pathGeneration == path.generation
                && path.activeNetworkProfiles.contains(peer.networkProfile)
                && peer.pathHints.allSatisfy { $0.isUsable(at: clock.now()) }
        }.sorted {
            if $0.interfaceIndex != $1.interfaceIndex {
                return $0.interfaceIndex < $1.interfaceIndex
            }
            return $0.pathHints[0].value < $1.pathHints[0].value
        }
        return current.isEmpty ? nil : .found(current)
    }

    private func clearResultsAndProfiles() async {
        let profiles = Set(results.values.flatMap { $0.values.map {
            ProfileGeneration(profile: $0.networkProfile, generation: $0.pathGeneration)
        } })
        results.removeAll(keepingCapacity: false)
        for value in profiles {
            await revokeProfile(value.profile, value.generation)
        }
    }

    private func waitForChangeOrTimeout(
        _ interval: TimeInterval,
        after generation: UInt64
    ) async {
        let changes = await changeSignal.events(after: generation)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes { return }
            }
            group.addTask { [clock] in try? await clock.sleep(for: interval) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
