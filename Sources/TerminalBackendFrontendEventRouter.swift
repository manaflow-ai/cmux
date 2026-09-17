import CmuxTerminalBackend
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
    let lifecycleWaiterCount: Int
    let rendererDeliveryCounts: [UUID: Int]
    let configDeliveryCounts: [UUID: Int]
}

/// A retry waits only for lifecycle changes capable of affecting its exact operation.
enum TerminalBackendRendererLifecycleKey: Hashable, Sendable {
    case any
    case workspace(UUID)
    case rendererEpoch(UInt64)
}

struct TerminalBackendRendererLifecycleCheckpoint: Equatable, Sendable {
    fileprivate let revision: UInt64
}

private enum TerminalBackendFrontendEventWork: Sendable {
    case renderer(TerminalBackendRendererEvent)
    case rendererResync
    case config(TerminalBackendRenderConfigSnapshot)
}

/// Process-wide fan-in for renderer lifecycle and finalized Ghostty config events.
///
/// The upstream pumps only ingest and key events. Every visible route owns one bounded,
/// serial mailbox so a slow AppKit handler cannot block reconnect ingestion or an
/// unrelated workspace. Dormant runtimes own neither a route nor a mailbox task.
actor TerminalBackendFrontendEventRouter {
    private static let lifecycleKeyCapacity = 1_024

    typealias RendererHandler = @MainActor @Sendable (
        TerminalBackendRendererEvent
    ) async -> Void
    typealias RendererStreamEndedHandler = @MainActor @Sendable () async -> Void
    typealias ConfigHandler = @MainActor @Sendable (
        TerminalBackendRenderConfigSnapshot
    ) async -> Void

    private struct Route: Sendable {
        let token: TerminalBackendFrontendEventRoute
        var presentationID: UUID
        var workspaceID: UUID
        let mailbox: TerminalBackendFrontendEventMailbox
    }

    private struct LifecycleWaiter {
        let key: TerminalBackendRendererLifecycleKey
        let checkpoint: TerminalBackendRendererLifecycleCheckpoint
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let client: any TerminalBackendClient
    private var configUpdates: AsyncStream<TerminalBackendRenderConfigSnapshot>?
    private var pendingConfigUpdates: AsyncStream<TerminalBackendRenderConfigSnapshot>?
    private var rendererPump: Task<Void, Never>?
    private var rendererPumpGeneration = UUID()
    private var rendererPumpReadyGeneration: UUID?
    private var rendererPumpReadyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var configPump: Task<Void, Never>?
    private var configPumpGeneration = UUID()
    private var rendererUpstreamSubscriptionCount = 0
    private var configUpstreamSubscriptionCount = 0

    private var routes: [UUID: Route] = [:]
    private var routeIDsByPresentationID: [UUID: Set<UUID>] = [:]
    private var routeIDsByWorkspaceID: [UUID: Set<UUID>] = [:]
    private var latestConfig: TerminalBackendRenderConfigSnapshot?
    private var latestConnectionEvent: TerminalBackendRendererEvent?
    private var rendererStateRequiresResync = false

    private var lifecycleRevision: UInt64 = 0
    private var globalLifecycleRevision: UInt64 = 0
    private var workspaceLifecycleRevisions: [UUID: UInt64] = [:]
    private var rendererEpochLifecycleRevisions: [UInt64: UInt64] = [:]
    private var lifecycleWaiters: [UUID: LifecycleWaiter] = [:]

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
        rendererPumpReadyWaiters.values.forEach { $0.resume(returning: false) }
        lifecycleWaiters.values.forEach { $0.continuation.resume(returning: false) }
    }

    func start() {
        startRendererPumpIfNeeded()
        startConfigPumpIfNeeded()
    }

    func installConfigUpdates(
        _ updates: AsyncStream<TerminalBackendRenderConfigSnapshot>
    ) {
        guard configUpdates == nil else {
            pendingConfigUpdates = updates
            return
        }
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
        var initialWork: [TerminalBackendFrontendEventWork] = []
        if let latestConfig {
            initialWork.append(.config(latestConfig))
            recordConfigDelivery(presentationID: presentationID)
        }
        if rendererStateRequiresResync {
            initialWork.append(.rendererResync)
        } else if let latestConnectionEvent {
            initialWork.append(.renderer(latestConnectionEvent))
            recordRendererDelivery(presentationID: presentationID)
        }
        let mailbox = TerminalBackendFrontendEventMailbox(
            initialWork: initialWork,
            rendererHandler: rendererHandler,
            rendererStreamEndedHandler: rendererStreamEndedHandler,
            configHandler: configHandler
        )
        let route = Route(
            token: token,
            presentationID: presentationID,
            workspaceID: workspaceID,
            mailbox: mailbox
        )
        routes[token.identifier] = route
        routeIDsByPresentationID[presentationID, default: []].insert(token.identifier)
        routeIDsByWorkspaceID[workspaceID, default: []].insert(token.identifier)
        resumeRouteCountWaiters()
        await mailbox.start()
        return token
    }

    func reindex(
        _ token: TerminalBackendFrontendEventRoute,
        presentationID: UUID,
        workspaceID: UUID
    ) {
        guard var route = routes[token.identifier] else { return }
        guard route.presentationID != presentationID || route.workspaceID != workspaceID else {
            return
        }
        let oldPresentationID = route.presentationID
        remove(
            token.identifier,
            from: &routeIDsByPresentationID,
            key: oldPresentationID
        )
        remove(
            token.identifier,
            from: &routeIDsByWorkspaceID,
            key: route.workspaceID
        )
        route.presentationID = presentationID
        route.workspaceID = workspaceID
        routes[token.identifier] = route
        routeIDsByPresentationID[presentationID, default: []].insert(token.identifier)
        routeIDsByWorkspaceID[workspaceID, default: []].insert(token.identifier)
        if routeIDsByPresentationID[oldPresentationID] == nil {
            rendererDeliveryCounts.removeValue(forKey: oldPresentationID)
            configDeliveryCounts.removeValue(forKey: oldPresentationID)
        }
    }

    func unregister(_ token: TerminalBackendFrontendEventRoute) async {
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
        if routeIDsByPresentationID[route.presentationID] == nil {
            rendererDeliveryCounts.removeValue(forKey: route.presentationID)
            configDeliveryCounts.removeValue(forKey: route.presentationID)
        }
        resumeRouteCountWaiters()
        await route.mailbox.cancel()
    }

    func snapshot() -> TerminalBackendFrontendEventRouterSnapshot {
        TerminalBackendFrontendEventRouterSnapshot(
            rendererUpstreamSubscriptionCount: rendererUpstreamSubscriptionCount,
            configUpstreamSubscriptionCount: configUpstreamSubscriptionCount,
            activeRouteCount: routes.count,
            lifecycleWaiterCount: lifecycleWaiters.count,
            rendererDeliveryCounts: rendererDeliveryCounts,
            configDeliveryCounts: configDeliveryCounts
        )
    }

    func lifecycleCheckpoint() async -> TerminalBackendRendererLifecycleCheckpoint? {
        guard await waitForRendererPumpReadiness() else { return nil }
        return TerminalBackendRendererLifecycleCheckpoint(revision: lifecycleRevision)
    }

    func waitForLifecycleChange(
        after checkpoint: TerminalBackendRendererLifecycleCheckpoint,
        key: TerminalBackendRendererLifecycleKey
    ) async -> Bool {
        if lifecycleAdvanced(for: key, after: checkpoint) { return true }
        if Task.isCancelled { return false }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if lifecycleAdvanced(for: key, after: checkpoint) {
                    continuation.resume(returning: true)
                } else {
                    lifecycleWaiters[identifier] = LifecycleWaiter(
                        key: key,
                        checkpoint: checkpoint,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelLifecycleWaiter(identifier) }
        }
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
        rendererPumpReadyGeneration = nil
        let generation = rendererPumpGeneration
        let client = client
        rendererUpstreamSubscriptionCount += 1
        rendererPump = Task { [weak self, client] in
            let events = await client.rendererEvents()
            guard !Task.isCancelled else { return }
            await self?.rendererPumpDidSubscribe(generation: generation)
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.routeRenderer(event)
            }
            guard !Task.isCancelled else { return }
            await self?.rendererPumpEnded(generation: generation)
        }
    }

    private func rendererPumpDidSubscribe(generation: UUID) {
        guard rendererPumpGeneration == generation else { return }
        rendererPumpReadyGeneration = generation
        // Existing routes already own an authoritative resync item. A route
        // registered after the replacement subscription can reconcile directly
        // and must not inherit the completed stream's overflow sentinel forever.
        rendererStateRequiresResync = false
        let waiters = rendererPumpReadyWaiters.values
        rendererPumpReadyWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    private func waitForRendererPumpReadiness() async -> Bool {
        startRendererPumpIfNeeded()
        if rendererPumpReadyGeneration == rendererPumpGeneration { return true }
        if Task.isCancelled { return false }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if rendererPumpReadyGeneration == rendererPumpGeneration {
                    continuation.resume(returning: true)
                } else {
                    rendererPumpReadyWaiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRendererPumpReadyWaiter(identifier) }
        }
    }

    private func cancelRendererPumpReadyWaiter(_ identifier: UUID) {
        rendererPumpReadyWaiters.removeValue(forKey: identifier)?.resume(returning: false)
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
        rendererPumpReadyGeneration = nil
        latestConnectionEvent = nil
        rendererStateRequiresResync = true
        advanceGlobalLifecycle()
        for route in Array(routes.values) {
            guard routes[route.token.identifier] != nil else { continue }
            await route.mailbox.enqueue(.rendererResync)
        }
        guard rendererPumpGeneration == generation else { return }
        rendererPump = nil
        startRendererPumpIfNeeded()
    }

    private func configPumpEnded(generation: UUID) {
        guard configPumpGeneration == generation else { return }
        configPump = nil
        configUpdates = pendingConfigUpdates
        pendingConfigUpdates = nil
        startConfigPumpIfNeeded()
    }

    private func routeRenderer(_ event: TerminalBackendRendererEvent) async {
        let routeIDs: Set<UUID>
        switch event {
        case .workerChanged(let presentationID, let changed):
            advanceWorkspaceLifecycle(changed)
            routeIDs = routeIDsByPresentationID[presentationID] ?? []
        case .presentationReady(let presentationID, _):
            routeIDs = routeIDsByPresentationID[presentationID] ?? []
        case .presentationInvalidated(let presentationID):
            advancePresentationLifecycle(presentationID)
            routeIDs = routeIDsByPresentationID[presentationID] ?? []
        case .connectionLost:
            advanceGlobalLifecycle()
            latestConnectionEvent = event
            rendererStateRequiresResync = false
            routeIDs = Set(routes.keys)
        case .reconnected:
            advanceGlobalLifecycle()
            latestConnectionEvent = event
            rendererStateRequiresResync = false
            routeIDs = Set(routes.keys)
        }
        for identifier in routeIDs {
            guard let route = routes[identifier] else { continue }
            if case .presentationInvalidated = event {
                await route.mailbox.enqueue(.rendererResync)
            } else {
                await route.mailbox.enqueue(.renderer(event))
            }
            guard let currentRoute = routes[identifier], routeStillMatches(
                currentRoute,
                event: event
            ) else { continue }
            recordRendererDelivery(presentationID: currentRoute.presentationID)
        }
    }

    private func routeConfig(_ update: TerminalBackendRenderConfigSnapshot) async {
        latestConfig = update
        for route in Array(routes.values) {
            guard routes[route.token.identifier] != nil else { continue }
            await route.mailbox.enqueue(.config(update))
            guard let currentRoute = routes[route.token.identifier] else { continue }
            recordConfigDelivery(presentationID: currentRoute.presentationID)
        }
    }

    private func routeStillMatches(
        _ route: Route,
        event: TerminalBackendRendererEvent
    ) -> Bool {
        switch event {
        case .workerChanged(let presentationID, let changed):
            return route.presentationID == presentationID
                && route.workspaceID == changed.workspaceID.rawValue
        case .presentationReady(let presentationID, _):
            return route.presentationID == presentationID
        case .presentationInvalidated(let presentationID):
            return route.presentationID == presentationID
        case .connectionLost, .reconnected:
            return true
        }
    }

    private func advanceGlobalLifecycle() {
        advanceLifecycleRevision()
        globalLifecycleRevision = lifecycleRevision
        resumeLifecycleWaiters()
    }

    private func advanceWorkspaceLifecycle(_ changed: BackendRendererWorkerChanged) {
        advanceLifecycleRevision()
        workspaceLifecycleRevisions[changed.workspaceID.rawValue] = lifecycleRevision
        if changed.priorRendererEpoch > 0 {
            rendererEpochLifecycleRevisions[changed.priorRendererEpoch] = lifecycleRevision
        }
        if let rendererEpoch = changed.rendererEpoch {
            rendererEpochLifecycleRevisions[rendererEpoch] = lifecycleRevision
        }
        if workspaceLifecycleRevisions.count > Self.lifecycleKeyCapacity
            || rendererEpochLifecycleRevisions.count > Self.lifecycleKeyCapacity {
            // A bounded-key overflow is itself a global resynchronization point.
            // Pending exact waiters retry once instead of losing a lifecycle edge.
            globalLifecycleRevision = lifecycleRevision
            workspaceLifecycleRevisions.removeAll(keepingCapacity: true)
            rendererEpochLifecycleRevisions.removeAll(keepingCapacity: true)
        }
        resumeLifecycleWaiters()
    }

    private func advancePresentationLifecycle(_ presentationID: UUID) {
        advanceLifecycleRevision()
        for identifier in routeIDsByPresentationID[presentationID] ?? [] {
            guard let route = routes[identifier] else { continue }
            workspaceLifecycleRevisions[route.workspaceID] = lifecycleRevision
        }
        resumeLifecycleWaiters()
    }

    private func advanceLifecycleRevision() {
        lifecycleRevision &+= 1
        if lifecycleRevision == 0 { lifecycleRevision = 1 }
    }

    private func lifecycleAdvanced(
        for key: TerminalBackendRendererLifecycleKey,
        after checkpoint: TerminalBackendRendererLifecycleCheckpoint
    ) -> Bool {
        let relevantRevision: UInt64
        switch key {
        case .any:
            relevantRevision = lifecycleRevision
        case .workspace(let workspaceID):
            relevantRevision = max(
                globalLifecycleRevision,
                workspaceLifecycleRevisions[workspaceID, default: 0]
            )
        case .rendererEpoch(let rendererEpoch):
            relevantRevision = max(
                globalLifecycleRevision,
                rendererEpochLifecycleRevisions[rendererEpoch, default: 0]
            )
        }
        return relevantRevision != 0 && relevantRevision > checkpoint.revision
    }

    private func resumeLifecycleWaiters() {
        let satisfied = lifecycleWaiters.compactMap { identifier, waiter in
            lifecycleAdvanced(for: waiter.key, after: waiter.checkpoint)
                ? identifier
                : nil
        }
        for identifier in satisfied {
            lifecycleWaiters.removeValue(forKey: identifier)?
                .continuation.resume(returning: true)
        }
    }

    private func cancelLifecycleWaiter(_ identifier: UUID) {
        lifecycleWaiters.removeValue(forKey: identifier)?
            .continuation.resume(returning: false)
    }

    private func recordRendererDelivery(presentationID: UUID) {
        rendererDeliveryCounts[presentationID, default: 0] += 1
        rendererDeliveryTotal += 1
        resumeRendererDeliveryWaiters()
    }

    private func recordConfigDelivery(presentationID: UUID) {
        configDeliveryCounts[presentationID, default: 0] += 1
        configDeliveryTotal += 1
        resumeConfigDeliveryWaiters()
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

/// One visible route's bounded serial executor. Its actor never awaits upstream work;
/// only its own handler can suspend, so another route and the process pump keep moving.
private actor TerminalBackendFrontendEventMailbox {
    private static let capacity = 32

    private let rendererHandler: TerminalBackendFrontendEventRouter.RendererHandler
    private let rendererStreamEndedHandler:
        TerminalBackendFrontendEventRouter.RendererStreamEndedHandler
    private let configHandler: TerminalBackendFrontendEventRouter.ConfigHandler
    private var pending: [TerminalBackendFrontendEventWork]
    private var runner: Task<Void, Never>?
    private var runnerGeneration = UUID()
    private var cancelled = false
    private var resyncOutstanding: Bool

    init(
        initialWork: [TerminalBackendFrontendEventWork],
        rendererHandler: @escaping TerminalBackendFrontendEventRouter.RendererHandler,
        rendererStreamEndedHandler: @escaping
            TerminalBackendFrontendEventRouter.RendererStreamEndedHandler,
        configHandler: @escaping TerminalBackendFrontendEventRouter.ConfigHandler
    ) {
        self.pending = initialWork
        self.rendererHandler = rendererHandler
        self.rendererStreamEndedHandler = rendererStreamEndedHandler
        self.configHandler = configHandler
        self.resyncOutstanding = initialWork.contains { work in
            if case .rendererResync = work { return true }
            return false
        }
    }

    deinit {
        runner?.cancel()
    }

    func start() {
        startRunnerIfNeeded()
    }

    func enqueue(_ work: TerminalBackendFrontendEventWork) {
        guard !cancelled else { return }
        switch work {
        case .renderer:
            guard !resyncOutstanding else { return }
            if pending.count >= Self.capacity {
                replacePendingWithResync()
            } else {
                pending.append(work)
            }
        case .rendererResync:
            guard !resyncOutstanding else { return }
            replacePendingWithResync()
        case .config(let update):
            pending.removeAll { candidate in
                if case .config = candidate { return true }
                return false
            }
            if pending.count >= Self.capacity {
                replacePendingWithResync(preserving: update)
            } else {
                pending.append(.config(update))
            }
        }
        startRunnerIfNeeded()
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        pending.removeAll()
        resyncOutstanding = false
        runnerGeneration = UUID()
        runner?.cancel()
        runner = nil
    }

    private func replacePendingWithResync(
        preserving config: TerminalBackendRenderConfigSnapshot? = nil
    ) {
        let newestConfig = config ?? pending.reversed().compactMap { work in
            if case .config(let update) = work { return update }
            return nil
        }.first
        pending.removeAll()
        pending.append(.rendererResync)
        resyncOutstanding = true
        if let newestConfig {
            pending.append(.config(newestConfig))
        }
    }

    private func startRunnerIfNeeded() {
        guard !cancelled, runner == nil, !pending.isEmpty else { return }
        runnerGeneration = UUID()
        let generation = runnerGeneration
        runner = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: UUID) async {
        while !cancelled, !Task.isCancelled, !pending.isEmpty {
            let work = pending.removeFirst()
            switch work {
            case .renderer(let event):
                await rendererHandler(event)
            case .rendererResync:
                await rendererStreamEndedHandler()
                resyncOutstanding = false
            case .config(let update):
                await configHandler(update)
            }
        }
        guard runnerGeneration == generation else { return }
        runner = nil
        startRunnerIfNeeded()
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
