import AppKit
import Observation

/// Owns every main-window route from registration through recovery or close.
///
/// `AppDelegate` remains the composition root, but it no longer keeps a
/// registered-context dictionary and a separate recovery ledger that can
/// disagree about the same window.
@MainActor
@Observable
final class MainWindowLifecycleCoordinator {
    private var recordsByWindowId: [UUID: MainWindowLifecycleRecord] = [:]
    private(set) var registeredContextsByLookupKey:
        [ObjectIdentifier: AppDelegate.MainWindowContext] = [:]
    private let maximumFrozenOrphanRecords: Int
    private var nextOrder: UInt64 = 0
    private(set) var persistenceTopologyRevision: UInt64 = 0
    @ObservationIgnored
    private var windowlessRecoveryResumeIndexesTask:
        Task<ProcessDetectedResumeIndexes?, Never>?
    @ObservationIgnored
    private var windowlessRecoveryResumeIndexesWorkerTask:
        (token: UUID, task: Task<Void, Never>)?
    @ObservationIgnored
    private var windowlessRouteFreezeTasks:
        [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored
    private var windowlessRecoveryResumeIndexesBindings:
        [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
    @ObservationIgnored
    private var windowlessRecoveryTTYDeviceBindings:
        [SurfaceResumeBindingIndex.PanelKey: Int64]?
    @ObservationIgnored
    private var windowlessRecoveryResumeIndexesGeneration: UInt64 = 0

    deinit {
        windowlessRouteFreezeTasks.values.forEach { $0.task.cancel() }
        windowlessRecoveryResumeIndexesTask?.cancel()
        windowlessRecoveryResumeIndexesWorkerTask?.task.cancel()
    }

    init(
        maximumFrozenOrphanRecords: Int = SessionPersistencePolicy.maxWindowsPerSnapshot
    ) {
        self.maximumFrozenOrphanRecords = max(0, maximumFrozenOrphanRecords)
    }

    /// Coalesces process/filesystem detection shared by windowless orphan freezes.
    ///
    /// A window prune can orphan several windows in one turn. One coordinator-owned
    /// task keeps those routes on the same scan generation and prevents each route
    /// from starting an independent process snapshot and registry walk. A nil
    /// result means fresh detection was unavailable; callers must preserve stored
    /// bindings through the manual/fail-closed path instead of treating it as an
    /// authoritative empty scan.
    func loadWindowlessRecoveryResumeIndexes(
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64],
        loader: @escaping @Sendable (
            [SurfaceResumeBindingIndex.PanelKey: Int64]
        ) async -> ProcessDetectedResumeIndexes?
    ) async -> ProcessDetectedResumeIndexes? {
        for (key, device) in ttyDeviceBindings where
            windowlessRecoveryResumeIndexesBindings[key] == nil {
            windowlessRecoveryResumeIndexesBindings[key] = device
        }
        windowlessRecoveryResumeIndexesGeneration &+= 1
        if let task = windowlessRecoveryResumeIndexesTask {
            return await task.value
        }
        // A timed-out synchronous worker may still be finishing. Fail closed for
        // this caller and let the coordinator-owned completion task clear it;
        // never start a second process/filesystem scan concurrently.
        guard windowlessRecoveryResumeIndexesWorkerTask == nil else {
            return nil
        }
        let task: Task<ProcessDetectedResumeIndexes?, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return nil
            }
            return await self.runWindowlessRecoveryResumeIndexesLoad(loader: loader)
        }
        windowlessRecoveryResumeIndexesTask = task
        return await task.value
    }

    /// Captures the global TTY map once, then merges route-local additions.
    func windowlessRecoveryTTYDeviceBindings(
        allBindingsProvider: @MainActor () -> [SurfaceResumeBindingIndex.PanelKey: Int64],
        routeBindings: [SurfaceResumeBindingIndex.PanelKey: Int64]
    ) -> [SurfaceResumeBindingIndex.PanelKey: Int64] {
        if windowlessRecoveryTTYDeviceBindings == nil {
            windowlessRecoveryTTYDeviceBindings = allBindingsProvider()
        }
        for (key, device) in routeBindings where
            windowlessRecoveryTTYDeviceBindings?[key] == nil {
            windowlessRecoveryTTYDeviceBindings?[key] = device
        }
        return windowlessRecoveryTTYDeviceBindings ?? [:]
    }

    private func runWindowlessRecoveryResumeIndexesLoad(
        loader: @escaping @Sendable (
            [SurfaceResumeBindingIndex.PanelKey: Int64]
        ) async -> ProcessDetectedResumeIndexes?
    ) async -> ProcessDetectedResumeIndexes? {
        // One retry captures bindings that arrive while the first scan is off-main;
        // persistent churn fails closed instead of keeping a prune alive forever.
        let maximumAttempts = 2
        var attempts = 0
        while !Task.isCancelled && attempts < maximumAttempts {
            attempts += 1
            let scanGeneration = windowlessRecoveryResumeIndexesGeneration
            let scanBindings = windowlessRecoveryResumeIndexesBindings
            let indexes = await loader(scanBindings)
            guard !Task.isCancelled else { break }
            guard let indexes else {
                // An unavailable fresh scan must not immediately launch another
                // worker; its handle remains coalesced until the worker exits.
                // Keep bindings that arrived while the scan was running so the
                // next pass can retry them once that worker has drained.
                if scanGeneration == windowlessRecoveryResumeIndexesGeneration {
                    windowlessRecoveryResumeIndexesBindings.removeAll(keepingCapacity: false)
                    windowlessRecoveryTTYDeviceBindings = nil
                }
                windowlessRecoveryResumeIndexesTask = nil
                return nil
            }
            guard scanGeneration == windowlessRecoveryResumeIndexesGeneration else {
                continue
            }
            windowlessRecoveryResumeIndexesBindings.removeAll(keepingCapacity: false)
            windowlessRecoveryTTYDeviceBindings = nil
            windowlessRecoveryResumeIndexesTask = nil
            return indexes
        }

        if !Task.isCancelled {
            // The bounded retry exhausted without cancellation. Drop the
            // completed task so a later orphan can start a fresh generation.
            windowlessRecoveryResumeIndexesBindings.removeAll(keepingCapacity: false)
            windowlessRecoveryTTYDeviceBindings = nil
            windowlessRecoveryResumeIndexesTask = nil
        }
        return nil
    }

    /// Cancels a pending detection once no live windowless orphan still needs it.
    func cancelWindowlessRecoveryResumeIndexesLoadIfUnused() {
        let hasPendingWindowlessOrphan = recordsByWindowId.values.contains { record in
            guard case .orphaned(let route) = record.phase else { return false }
            return route.window == nil && route.frozenWindowSnapshot == nil
        }
        guard !hasPendingWindowlessOrphan else { return }
        windowlessRecoveryResumeIndexesGeneration &+= 1
        windowlessRecoveryResumeIndexesTask?.cancel()
        windowlessRecoveryResumeIndexesTask = nil
        windowlessRecoveryResumeIndexesWorkerTask?.task.cancel()
        windowlessRecoveryResumeIndexesBindings.removeAll(keepingCapacity: false)
        windowlessRecoveryTTYDeviceBindings = nil
    }

    /// Retains a timed-out process scan until its synchronous worker really exits.
    ///
    /// Cancellation cannot interrupt a synchronous process/filesystem call. Keeping
    /// this handle prevents a later orphan from starting an overlapping scan.
    func retainWindowlessRecoveryResumeIndexesWorker(
        _ task: Task<ProcessDetectedResumeIndexes, Never>
    ) {
        guard windowlessRecoveryResumeIndexesWorkerTask == nil else { return }
        let token = UUID()
        let completionTask = Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            guard self.windowlessRecoveryResumeIndexesWorkerTask?.token == token else {
                return
            }
            self.windowlessRecoveryResumeIndexesWorkerTask = nil
        }
        windowlessRecoveryResumeIndexesWorkerTask = (token: token, task: completionTask)
    }

    /// Owns one deferred freeze task until it completes or its route leaves recovery.
    ///
    /// The token prevents an older task's completion callback from removing a newer
    /// task that was scheduled for the same window id after a reattachment race.
    func retainWindowlessRouteFreezeTask(
        _ task: Task<Void, Never>,
        windowId: UUID,
        token: UUID
    ) {
        windowlessRouteFreezeTasks[windowId]?.task.cancel()
        windowlessRouteFreezeTasks[windowId] = (token: token, task: task)
    }

    /// Drops a completed deferred freeze task without touching a replacement task.
    func releaseWindowlessRouteFreezeTask(windowId: UUID, token: UUID) {
        guard windowlessRouteFreezeTasks[windowId]?.token == token else { return }
        windowlessRouteFreezeTasks.removeValue(forKey: windowId)
    }

    /// Cancels and forgets the deferred freeze for one route.
    func cancelWindowlessRouteFreezeTask(windowId: UUID) {
        guard let entry = windowlessRouteFreezeTasks.removeValue(forKey: windowId) else {
            return
        }
        entry.task.cancel()
    }

    /// Cancels every deferred freeze when the coordinator's owner is tearing down.
    func cancelAllWindowlessRouteFreezeTasks() {
        windowlessRouteFreezeTasks.values.forEach { $0.task.cancel() }
        windowlessRouteFreezeTasks.removeAll(keepingCapacity: false)
        windowlessRecoveryResumeIndexesTask?.cancel()
        windowlessRecoveryResumeIndexesTask = nil
        windowlessRecoveryResumeIndexesWorkerTask?.task.cancel()
    }

    /// Indicates whether a windowless route is within the caller's bounded orphan set.
    func shouldFreezeWindowlessRoute(
        windowId: UUID,
        availablePersistenceSlots: Int
    ) -> Bool {
        guard orphanedRoute(windowId: windowId)?.window == nil else { return false }
        return eligibleOrphanedRoutesForPersistence(
            maximum: availablePersistenceSlots
        )
            .contains { $0.windowId == windowId }
    }

    /// Returns the bounded orphan set that can occupy persisted window slots.
    func eligibleOrphanedRoutesForPersistence(
        maximum: Int = SessionPersistencePolicy.maxWindowsPerSnapshot
    ) -> [RecoverableMainWindowRoute] {
        orphanedRoutes()
            .filter(\.isEligibleForSessionPersistence)
            .prefix(max(0, maximum))
            .map { $0 }
    }

    var registeredContexts: [AppDelegate.MainWindowContext] {
        Array(registeredContextsByLookupKey.values)
    }

    /// Replaces the lookup index while preserving lifecycle records.
    ///
    /// AppKit can briefly hand back a window under a different object identity;
    /// the composition root uses this bounded repair operation to rebuild the
    /// exact-window index without maintaining a second source of truth.
    func replaceRegisteredContextLookups(
        _ contexts: [ObjectIdentifier: AppDelegate.MainWindowContext]
    ) {
        var lookupKeysByWindowId: [UUID: ObjectIdentifier] = [:]
        for (lookupKey, context) in contexts {
            // A repaired index must still have one exact lookup identity per
            // stable window id. Refuse an ambiguous replacement rather than
            // making the record/index pair disagree again.
            guard lookupKeysByWindowId[context.windowId] == nil else { return }
            lookupKeysByWindowId[context.windowId] = lookupKey
        }

        var updatedRecords = recordsByWindowId
        for (windowId, record) in recordsByWindowId {
            guard case .registered = record.phase else { continue }
            guard let lookupKey = lookupKeysByWindowId[windowId] else {
                // Keep the existing index untouched when a caller attempts to
                // drop a registered context without first transitioning it.
                return
            }
            var updatedRecord = record
            updatedRecord.phase = .registered(lookupKey: lookupKey)
            updatedRecords[windowId] = updatedRecord
        }

        registeredContextsByLookupKey = contexts
        recordsByWindowId = updatedRecords
    }

    /// Inserts a standalone recoverable route for legacy callers that do not
    /// have a live ``MainWindowContext`` (for example, a windowless restore
    /// owner created by a test or a headless lifecycle entrypoint).
    @discardableResult
    func rememberStandaloneOrphanedRoute(
        _ route: RecoverableMainWindowRoute
    ) -> Bool {
        guard recordsByWindowId[route.windowId] == nil else { return false }
        recordsByWindowId[route.windowId] = MainWindowLifecycleRecord(
            order: issueOrder(),
            phase: .orphaned(route)
        )
        bumpPersistenceTopologyRevision()
        return true
    }

    func registeredContext(for lookupKey: ObjectIdentifier) -> AppDelegate.MainWindowContext? {
        registeredContextsByLookupKey[lookupKey]
    }

    func registeredContext(windowId: UUID) -> AppDelegate.MainWindowContext? {
        guard let record = recordsByWindowId[windowId],
              case .registered(let lookupKey) = record.phase else {
            return nil
        }
        return registeredContextsByLookupKey[lookupKey]
    }

    @discardableResult
    func register(
        _ context: AppDelegate.MainWindowContext,
        lookupKey: ObjectIdentifier
    ) -> AppDelegate.MainWindowContext? {
        if var record = recordsByWindowId[context.windowId] {
            switch record.phase {
            case .registered(let previousLookupKey):
                guard registeredContextsByLookupKey[previousLookupKey] === context else {
                    return nil
                }
                if let conflict = registeredContextsByLookupKey[lookupKey],
                   conflict !== context {
                    return nil
                }
                registeredContextsByLookupKey.removeValue(forKey: previousLookupKey)
                registeredContextsByLookupKey[lookupKey] = context
                record.phase = .registered(lookupKey: lookupKey)
                recordsByWindowId[context.windowId] = record
                bumpPersistenceTopologyRevision()
                return context

            case .orphaned(let route):
                guard registeredContextsByLookupKey[lookupKey] == nil,
                      let reattached = route.takeContextForRegistration(
                          matching: context
                      ) else {
                    return nil
                }
                cancelWindowlessRouteFreezeTask(windowId: context.windowId)
                registeredContextsByLookupKey[lookupKey] = reattached
                record.phase = .registered(lookupKey: lookupKey)
                recordsByWindowId[context.windowId] = record
                bumpPersistenceTopologyRevision()
                return reattached

            case .closing:
                return nil
            }
        }

        guard registeredContextsByLookupKey[lookupKey] == nil else { return nil }
        registeredContextsByLookupKey[lookupKey] = context
        recordsByWindowId[context.windowId] = MainWindowLifecycleRecord(
            order: issueOrder(),
            phase: .registered(lookupKey: lookupKey)
        )
        bumpPersistenceTopologyRevision()
        return context
    }

    func contains(windowId: UUID) -> Bool {
        recordsByWindowId[windowId] != nil
    }

    @discardableResult
    func reindex(
        _ context: AppDelegate.MainWindowContext,
        lookupKey: ObjectIdentifier
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let previousLookupKey) = record.phase,
              registeredContextsByLookupKey[previousLookupKey] === context else {
            return false
        }
        if previousLookupKey == lookupKey {
            return true
        }
        if let conflicting = registeredContextsByLookupKey[lookupKey],
           conflicting !== context {
            return false
        }

        registeredContextsByLookupKey.removeValue(forKey: previousLookupKey)
        registeredContextsByLookupKey[lookupKey] = context
        record.phase = .registered(lookupKey: lookupKey)
        recordsByWindowId[context.windowId] = record
        return true
    }

    @discardableResult
    func transitionToOrphaned(
        _ route: RecoverableMainWindowRoute,
        from context: AppDelegate.MainWindowContext
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let lookupKey) = record.phase,
              registeredContextsByLookupKey[lookupKey] === context,
              route.frozenWindowSnapshot != nil
                || route.retainContextForOrphaning(context) else {
            return false
        }
        registeredContextsByLookupKey.removeValue(forKey: lookupKey)
        cancelWindowlessRouteFreezeTask(windowId: context.windowId)
        record.order = issueOrder()
        record.phase = .orphaned(route)
        recordsByWindowId[context.windowId] = record
        trimFrozenOrphanRecordsToLimit()
        bumpPersistenceTopologyRevision()
        return true
    }

    @discardableResult
    func transitionToClosing(
        _ route: RecoverableMainWindowRoute,
        from context: AppDelegate.MainWindowContext
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let lookupKey) = record.phase,
              registeredContextsByLookupKey[lookupKey] === context else {
            return false
        }
        registeredContextsByLookupKey.removeValue(forKey: lookupKey)
        cancelWindowlessRouteFreezeTask(windowId: context.windowId)
        route.markForTeardown()
        record.phase = .closing(route)
        recordsByWindowId[context.windowId] = record
        bumpPersistenceTopologyRevision()
        return true
    }

    @discardableResult
    func transitionOrphanedRouteToClosing(
        windowId: UUID,
        window: NSWindow
    ) -> Bool {
        guard var record = recordsByWindowId[windowId],
              case .orphaned(let route) = record.phase,
              route.window === window else {
            return false
        }
        route.markForTeardown()
        cancelWindowlessRouteFreezeTask(windowId: windowId)
        record.phase = .closing(route)
        recordsByWindowId[windowId] = record
        bumpPersistenceTopologyRevision()
        return true
    }

    func orphanedRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard let record = recordsByWindowId[windowId],
              case .orphaned(let route) = record.phase else {
            return nil
        }
        return route
    }

    func orphanedRoutes() -> [RecoverableMainWindowRoute] {
        recordsByWindowId.values
            .compactMap { record -> (UInt64, RecoverableMainWindowRoute)? in
                guard case .orphaned(let route) = record.phase else { return nil }
                return (record.order, route)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                return lhs.1.windowId.uuidString < rhs.1.windowId.uuidString
            }
            .map { $0.1 }
    }

    @discardableResult
    func replaceOrphanedRoute(
        windowId: UUID,
        with replacement: RecoverableMainWindowRoute
    ) -> Bool {
        guard replacement.windowId == windowId,
              var record = recordsByWindowId[windowId],
              case .orphaned = record.phase else {
            return false
        }
        record.phase = .orphaned(replacement)
        recordsByWindowId[windowId] = record
        trimFrozenOrphanRecordsToLimit()
        bumpPersistenceTopologyRevision()
        return true
    }

    func teardownRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard let phase = recordsByWindowId[windowId]?.phase else { return nil }
        switch phase {
        case .registered:
            return nil
        case .orphaned(let route), .closing(let route):
            return route
        }
    }

    func removeRecoverableRoute(windowId: UUID) {
        guard let phase = recordsByWindowId[windowId]?.phase else { return }
        if case .registered = phase { return }
        cancelWindowlessRouteFreezeTask(windowId: windowId)
        recordsByWindowId.removeValue(forKey: windowId)
        bumpPersistenceTopologyRevision()
    }

    /// Consumes a persistence-only route when a reopen pass recreates its window.
    @discardableResult
    func removeFrozenOrphanRoute(windowId: UUID) -> Bool {
        guard let phase = recordsByWindowId[windowId]?.phase,
              case .orphaned(let route) = phase,
              route.frozenWindowSnapshot != nil else {
            return false
        }
        cancelWindowlessRouteFreezeTask(windowId: windowId)
        recordsByWindowId.removeValue(forKey: windowId)
        bumpPersistenceTopologyRevision()
        return true
    }

    func retireClosingRoutes(where shouldRetire: (RecoverableMainWindowRoute) -> Bool) -> Int {
        let windowIds = recordsByWindowId.compactMap { windowId, record -> UUID? in
            guard case .closing(let route) = record.phase,
                  shouldRetire(route) else {
                return nil
            }
            return windowId
        }
        for windowId in windowIds {
            cancelWindowlessRouteFreezeTask(windowId: windowId)
            recordsByWindowId.removeValue(forKey: windowId)
        }
        if !windowIds.isEmpty {
            bumpPersistenceTopologyRevision()
        }
        return windowIds.count
    }

    private func issueOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }

    /// Frozen routes have no live owner that can retire them later, so retain
    /// only the newest records that can appear in one persisted snapshot.
    private func trimFrozenOrphanRecordsToLimit() {
        let frozenRecords = recordsByWindowId.compactMap { windowId, record -> (UUID, UInt64)? in
            guard case .orphaned(let route) = record.phase,
                  route.frozenWindowSnapshot != nil else {
                return nil
            }
            return (windowId, record.order)
        }
        let excessCount = frozenRecords.count - maximumFrozenOrphanRecords
        guard excessCount > 0 else { return }

        let oldestWindowIds = frozenRecords
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.uuidString < rhs.0.uuidString
            }
            .prefix(excessCount)
            .map(\.0)
        for windowId in oldestWindowIds {
            cancelWindowlessRouteFreezeTask(windowId: windowId)
            recordsByWindowId.removeValue(forKey: windowId)
        }
    }

    private func bumpPersistenceTopologyRevision() {
        persistenceTopologyRevision &+= 1
    }
}
