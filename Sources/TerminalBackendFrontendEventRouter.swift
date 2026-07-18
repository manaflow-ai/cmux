import Foundation

/// One visible presentation's route into the process-wide frontend event router.
struct TerminalBackendFrontendEventRoute: Hashable, Sendable {
    fileprivate let identifier: UUID
}

/// Bounded diagnostics for proving that dormant presentations add no subscribers.
struct TerminalBackendFrontendEventRouterSnapshot: Equatable, Sendable {
    let rendererUpstreamSubscriptionCount: Int
    let configUpstreamSubscriptionCount: Int
    let activeRouteCount: Int
    let rendererDeliveryCounts: [UUID: Int]
    let configDeliveryCounts: [UUID: Int]
}

/// Process-wide fan-in for renderer lifecycle and finalized Ghostty config events.
///
/// The two upstream streams are consumed away from the main actor. Routes are indexed
/// by presentation and workspace so a renderer event reaches only affected visible
/// presentations. The handlers are main-actor isolated because they project the event
/// into AppKit state; dormant runtimes do not own a stream task or a router entry.
actor TerminalBackendFrontendEventRouter {
    typealias RendererHandler = @MainActor @Sendable (
        TerminalBackendRendererEvent
    ) async -> Void
    typealias RendererStreamEndedHandler = @MainActor @Sendable () async -> Void
    typealias ConfigHandler = @MainActor @Sendable (
        TerminalBackendRenderConfigSnapshot
    ) async -> Void

    private struct Route: Sendable {
        let token: TerminalBackendFrontendEventRoute
        let presentationID: UUID
        let workspaceID: UUID
        let rendererHandler: RendererHandler
        let rendererStreamEndedHandler: RendererStreamEndedHandler
        let configHandler: ConfigHandler
    }

    private let client: any TerminalBackendClient
    private var configUpdates: AsyncStream<TerminalBackendRenderConfigSnapshot>?
    private var rendererPump: Task<Void, Never>?
    private var rendererPumpGeneration = UUID()
    private var configPump: Task<Void, Never>?
    private var configPumpGeneration = UUID()
    private var rendererUpstreamSubscriptionCount = 0
    private var configUpstreamSubscriptionCount = 0

    private var routes: [UUID: Route] = [:]
    private var routeIDsByPresentationID: [UUID: Set<UUID>] = [:]
    private var routeIDsByWorkspaceID: [UUID: Set<UUID>] = [:]
    private var latestConfig: TerminalBackendRenderConfigSnapshot?
    private var latestConnectionEvent: TerminalBackendRendererEvent?

    private var rendererDeliveryCounts: [UUID: Int] = [:]
    private var configDeliveryCounts: [UUID: Int] = [:]
    private var rendererDeliveryTotal = 0
    private var configDeliveryTotal = 0
    private var routeCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var rendererDeliveryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var configDeliveryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(
        client: any TerminalBackendClient,
        configUpdates: AsyncStream<TerminalBackendRenderConfigSnapshot>?
    ) {
        self.client = client
        self.configUpdates = configUpdates
    }

    deinit {
        rendererPump?.cancel()
        configPump?.cancel()
    }

    func start() {
        startRendererPumpIfNeeded()
        startConfigPumpIfNeeded()
    }

    func installConfigUpdates(
        _ updates: AsyncStream<TerminalBackendRenderConfigSnapshot>
    ) {
        guard configUpdates == nil else { return }
        configUpdates = updates
        startConfigPumpIfNeeded()
    }

    func register(
        presentationID: UUID,
        workspaceID: UUID,
        rendererHandler: @escaping RendererHandler,
        rendererStreamEndedHandler: @escaping RendererStreamEndedHandler,
        configHandler: @escaping ConfigHandler
    ) async -> TerminalBackendFrontendEventRoute {
        start()
        let token = TerminalBackendFrontendEventRoute(identifier: UUID())
        let route = Route(
            token: token,
            presentationID: presentationID,
            workspaceID: workspaceID,
            rendererHandler: rendererHandler,
            rendererStreamEndedHandler: rendererStreamEndedHandler,
            configHandler: configHandler
        )
        routes[token.identifier] = route
        routeIDsByPresentationID[presentationID, default: []].insert(token.identifier)
        routeIDsByWorkspaceID[workspaceID, default: []].insert(token.identifier)
        resumeRouteCountWaiters()

        if let latestConfig {
            await deliverConfig(latestConfig, routeIDs: [token.identifier])
        }
        if let latestConnectionEvent {
            await deliverRenderer(latestConnectionEvent, routeIDs: [token.identifier])
        }
        return token
    }

    func unregister(_ token: TerminalBackendFrontendEventRoute) {
        guard let route = routes.removeValue(forKey: token.identifier) else { return }
        remove(
            token.identifier,
            from: &routeIDsByPresentationID,
            key: route.presentationID
        )
        remove(
            token.identifier,
            from: &routeIDsByWorkspaceID,
            key: route.workspaceID
        )
        resumeRouteCountWaiters()
    }

    func snapshot() -> TerminalBackendFrontendEventRouterSnapshot {
        TerminalBackendFrontendEventRouterSnapshot(
            rendererUpstreamSubscriptionCount: rendererUpstreamSubscriptionCount,
            configUpstreamSubscriptionCount: configUpstreamSubscriptionCount,
            activeRouteCount: routes.count,
            rendererDeliveryCounts: rendererDeliveryCounts,
            configDeliveryCounts: configDeliveryCounts
        )
    }

    func waitForRouteCount(_ count: Int) async {
        guard routes.count != count else { return }
        await withCheckedContinuation { continuation in
            routeCountWaiters[count, default: []].append(continuation)
        }
    }

    func waitForRendererDeliveryCount(_ count: Int) async {
        guard rendererDeliveryTotal < count else { return }
        await withCheckedContinuation { continuation in
            rendererDeliveryWaiters[count, default: []].append(continuation)
        }
    }

    func waitForConfigDeliveryCount(_ count: Int) async {
        guard configDeliveryTotal < count else { return }
        await withCheckedContinuation { continuation in
            configDeliveryWaiters[count, default: []].append(continuation)
        }
    }

    private func startRendererPumpIfNeeded() {
        guard rendererPump == nil else { return }
        rendererPumpGeneration = UUID()
        let generation = rendererPumpGeneration
        let client = client
        rendererUpstreamSubscriptionCount += 1
        rendererPump = Task { [weak self, client] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let events = await client.rendererEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.routeRenderer(event)
            }
            guard !Task.isCancelled else { return }
            await self?.rendererPumpEnded(generation: generation)
        }
    }

    private func startConfigPumpIfNeeded() {
        guard configPump == nil, let updates = configUpdates else { return }
        configPumpGeneration = UUID()
        let generation = configPumpGeneration
        configUpstreamSubscriptionCount += 1
        configPump = Task { [weak self, updates] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                await self?.routeConfig(update)
            }
            guard !Task.isCancelled else { return }
            await self?.configPumpEnded(generation: generation)
        }
    }

    private func rendererPumpEnded(generation: UUID) async {
        guard rendererPumpGeneration == generation else { return }
        rendererPump = nil
        let currentRoutes = Array(routes.values)
        for route in currentRoutes {
            guard routes[route.token.identifier] != nil else { continue }
            await route.rendererStreamEndedHandler()
        }
        // An overflowed coordinator stream is a resynchronization signal. Only
        // visible presentations need another subscription; a fully dormant
        // process leaves the failed pump stopped until the next registration.
        if !routes.isEmpty {
            startRendererPumpIfNeeded()
        }
    }

    private func configPumpEnded(generation: UUID) {
        guard configPumpGeneration == generation else { return }
        configPump = nil
    }

    private func routeRenderer(_ event: TerminalBackendRendererEvent) async {
        let routeIDs: Set<UUID>
        switch event {
        case .workerChanged(let changed):
            let workspaceID = changed.workspaceID.rawValue
            routeIDs = routeIDsByWorkspaceID[workspaceID] ?? []
        case .presentationReady(let presentationID, _):
            routeIDs = routeIDsByPresentationID[presentationID] ?? []
        case .connectionLost:
            latestConnectionEvent = event
            routeIDs = Set(routes.keys)
        case .reconnected:
            latestConnectionEvent = event
            routeIDs = Set(routes.keys)
        }
        await deliverRenderer(event, routeIDs: routeIDs)
    }

    private func routeConfig(_ update: TerminalBackendRenderConfigSnapshot) async {
        latestConfig = update
        await deliverConfig(update, routeIDs: Set(routes.keys))
    }

    private func deliverRenderer(
        _ event: TerminalBackendRendererEvent,
        routeIDs: Set<UUID>
    ) async {
        for identifier in routeIDs {
            guard let route = routes[identifier] else { continue }
            rendererDeliveryCounts[route.presentationID, default: 0] += 1
            rendererDeliveryTotal += 1
            resumeRendererDeliveryWaiters()
            await route.rendererHandler(event)
        }
    }

    private func deliverConfig(
        _ update: TerminalBackendRenderConfigSnapshot,
        routeIDs: Set<UUID>
    ) async {
        for identifier in routeIDs {
            guard let route = routes[identifier] else { continue }
            configDeliveryCounts[route.presentationID, default: 0] += 1
            configDeliveryTotal += 1
            resumeConfigDeliveryWaiters()
            await route.configHandler(update)
        }
    }

    private func remove<Key: Hashable>(
        _ identifier: UUID,
        from index: inout [Key: Set<UUID>],
        key: Key
    ) {
        index[key]?.remove(identifier)
        if index[key]?.isEmpty == true {
            index.removeValue(forKey: key)
        }
    }

    private func resumeRouteCountWaiters() {
        routeCountWaiters.removeValue(forKey: routes.count)?.forEach { $0.resume() }
    }

    private func resumeRendererDeliveryWaiters() {
        let satisfied = rendererDeliveryWaiters.keys.filter {
            $0 <= rendererDeliveryTotal
        }
        for count in satisfied {
            rendererDeliveryWaiters.removeValue(forKey: count)?.forEach { $0.resume() }
        }
    }

    private func resumeConfigDeliveryWaiters() {
        let satisfied = configDeliveryWaiters.keys.filter {
            $0 <= configDeliveryTotal
        }
        for count in satisfied {
            configDeliveryWaiters.removeValue(forKey: count)?.forEach { $0.resume() }
        }
    }
}

/// Main-actor identity registry that gives every runtime using the same backend client
/// the same router without adding a factory dependency to every panel call site.
@MainActor
final class TerminalBackendFrontendEventRouterRegistry {
    static let shared = TerminalBackendFrontendEventRouterRegistry()

    private struct Entry {
        weak var client: (any TerminalBackendClient)?
        weak var router: TerminalBackendFrontendEventRouter?
        weak var configSource: TerminalBackendRenderConfigSource?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func router(
        for client: any TerminalBackendClient,
        configSource: TerminalBackendRenderConfigSource?
    ) -> TerminalBackendFrontendEventRouter {
        let identifier = ObjectIdentifier(client)
        if var entry = entries[identifier],
           entry.client === client,
           let router = entry.router {
            if let configSource, entry.configSource == nil {
                entry.configSource = configSource
                entries[identifier] = entry
                let updates = configSource.updates()
                Task { await router.installConfigUpdates(updates) }
            } else if let configSource, let installed = entry.configSource {
                precondition(
                    installed === configSource,
                    "One backend client must use one process-wide render config source"
                )
            }
            return router
        }

        let updates = configSource?.updates()
        let router = TerminalBackendFrontendEventRouter(
            client: client,
            configUpdates: updates
        )
        entries[identifier] = Entry(
            client: client,
            router: router,
            configSource: configSource
        )
        Task { await router.start() }
        return router
    }
}
