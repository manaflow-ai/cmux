import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    typealias LoadResult = SharedLiveAgentIndexLoader.LoadResult
    typealias PanelKey = RestorableAgentSessionIndex.PanelKey
    typealias GenerationTimeoutWaiter = @Sendable () async -> Bool

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    var latestCompletedLoadResult: LoadResult?
    var latestCompletedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    var refreshGenerationsByID: [UUID: RefreshGeneration] = [:]
    var refreshTasksByID: [UUID: Task<LoadResult?, Never>] = [:]
    var refreshWorkTasksByID: [UUID: Task<Void, Never>] = [:]
    var refreshTimeoutTasksByID: [UUID: Task<Void, Never>] = [:]
    var refreshOutcomeContinuationsByID: [UUID: CheckedContinuation<LoadResult?, Never>] = [:]
    var refreshOutcomesByID: [UUID: RefreshOutcome] = [:]
    var resolvedRefreshOutcomeGenerationIDs = Set<UUID>()
    var capturingGenerationIDs = Set<UUID>()
    var refreshTailID: UUID?
    var nextRefreshOrdinal: UInt64 = 0
    var latestCompletedOrdinal: UInt64 = 0
    var pendingForkValidationGenerationByPanelID: [UUID: UUID] = [:]
    private var validatedForkPanelProbeCompletedAt: [PanelKey: Date] = [:]
    private var validatedForkPanels = Set<PanelKey>()
    private var validatedMissingForkPanels: [PanelKey: Date] = [:]
    private var processScopeFingerprint: Set<String> = []
    var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    static let maximumConcurrentPhysicalLoads = 2
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let processScopeFingerprintProvider: @Sendable () -> Set<String>
    let generationTimeoutWaiter: GenerationTimeoutWaiter
    private let hookStoreDirectoryProvider: @MainActor () -> String
    let dateProvider: @MainActor () -> Date

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        processScopeFingerprintProvider: @escaping @Sendable () -> Set<String> = {
            SharedLiveAgentIndexLoader.processScopeFingerprint(
                from: CmuxTopProcessSnapshot.captureCached(
                    includeProcessDetails: false,
                    maximumAge: 5
                )
            )
        },
        generationTimeoutWaiter: @escaping @Sendable () async -> Bool = {
            do {
                try await ContinuousClock().sleep(for: .seconds(5))
                return true
            } catch {
                return false
            }
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        }
    ) {
        self.indexLoader = indexLoader
        self.processScopeFingerprintProvider = processScopeFingerprintProvider
        self.generationTimeoutWaiter = generationTimeoutWaiter
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
    }

    deinit {
        for task in refreshTasksByID.values {
            task.cancel()
        }
        for task in refreshWorkTasksByID.values {
            task.cancel()
        }
        for task in refreshTimeoutTasksByID.values {
            task.cancel()
        }
        for continuation in refreshOutcomeContinuationsByID.values {
            continuation.resume(returning: nil)
        }
        deferredReloadTimer?.cancel()
        directoryWatchSource?.cancel()
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return (latestCompletedLoadResult?.index ?? index)?
            .snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for the Fork Conversation context menu. Never blocks.
    func snapshotForForkConversationCandidate(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard pendingForkValidationGenerationByPanelID[panelKey.panelId] == nil else {
            return nil
        }
        guard let index,
              validatedForkPanelKey(for: panelKey) != nil else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for an enabled Fork Conversation action. Never blocks.
    func snapshotForForkAvailability(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard pendingForkValidationGenerationByPanelID[panelKey.panelId] == nil,
              let validationKey = validatedForkPanelKey(for: panelKey),
              hasFreshForkAvailabilityProbe(for: validationKey),
              let index else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    func prepareForkAvailabilityProbe(workspaceId: UUID, panelId: UUID) -> Bool {
        let panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard pendingForkValidationGenerationByPanelID[panelKey.panelId] == nil else {
            return false
        }
        scheduleRefreshIfStale(validating: panelKey)
        guard pendingForkValidationGenerationByPanelID[panelKey.panelId] == nil else {
            return false
        }
        guard let index else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard index.snapshot(workspaceId: workspaceId, panelId: panelId) != nil else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard let validationKey = validatedForkPanelKey(for: panelKey) else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard hasFreshForkAvailabilityProbe(for: validationKey) else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        return true
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return cachedIndex()
    }

    /// Side-effect-free cached read for stale-tolerant consumers.
    func cachedIndex() -> RestorableAgentSessionIndex? {
        latestCompletedLoadResult?.index ?? index
    }

    /// Captures agent metadata off-main before the caller performs destructive teardown.
    /// Callers retain the terminal until this bounded generation resolves.
    func indexRefreshTaskForDestructiveClose() -> Task<RestorableAgentSessionIndex?, Never> {
        let refreshTask = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        return Task { @MainActor [self] in
            // The returned operation owns its coordinator until the requested
            // generation resolves, including for injected non-singleton indexes.
            defer { _ = self }
            await refreshTask.value?.index
        }
    }

    /// Returns the cached index after awaiting any stale refresh this call schedules.
    func indexRefreshingIfNeeded() async -> RestorableAgentSessionIndex? {
        guard let task = refreshTaskIfStale() else {
            return latestCompletedLoadResult?.index ?? index
        }
        // Later interactive successors intentionally do not extend this stale-tolerant
        // read. Hibernation performs a separate post-snapshot scoped capture before
        // teardown, while following an open-ended probe stream could starve its tick.
        return await task.value?.index ?? latestCompletedLoadResult?.index ?? index
    }

    /// Returns an immutable index from a capture that starts after this request,
    /// without publishing the result or notifying process-wide UI consumers.
    func scopedIndexCapturedAfterRequest() async -> RestorableAgentSessionIndex? {
        ensureWatchingHookStoreDirectory()
        let task = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        return await task.value?.index
    }

    /// Returns combined indexes from a generation whose physical capture starts after this request.
    func resumeIndexesCapturedAfterRequest() async -> ProcessDetectedResumeIndexes? {
        ensureWatchingHookStoreDirectory()
        let task = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        guard let result = await task.value else { return nil }
        return ProcessDetectedResumeIndexes(result)
    }

    /// Returns a recent combined result, joins the active generation, or starts one when stale.
    func resumeIndexesRefreshingIfNeeded(
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        ensureWatchingHookStoreDirectory()
        if refreshTailID != nil {
            let task = requestRefresh(
                freshness: .joinCurrentGeneration,
                publication: .scoped,
                validating: nil
            )
            return await task.value.map(ProcessDetectedResumeIndexes.init)
                ?? latestCompletedLoadResult.map(ProcessDetectedResumeIndexes.init)
        }
        if case .some = latestCompletedLoadResult,
           let latestCompletedAt,
           dateProvider().timeIntervalSince(latestCompletedAt) < maximumAge {
            let processScopeFingerprintProvider = self.processScopeFingerprintProvider
            let currentProcessScopeFingerprint = await Task.detached(priority: .utility) {
                processScopeFingerprintProvider()
            }.value
            if let currentResult = self.latestCompletedLoadResult,
               let currentCompletedAt = self.latestCompletedAt,
               dateProvider().timeIntervalSince(currentCompletedAt) < maximumAge,
               currentResult.processScopeFingerprint == currentProcessScopeFingerprint {
                return ProcessDetectedResumeIndexes(currentResult)
            }
            let task = requestRefresh(
                freshness: .captureAfterRequest,
                publication: .scoped,
                validating: nil
            )
            return await task.value.map(ProcessDetectedResumeIndexes.init)
                ?? self.latestCompletedLoadResult.map(ProcessDetectedResumeIndexes.init)
        }
        let task = requestRefresh(
            freshness: .joinCurrentGeneration,
            publication: .scoped,
            validating: nil
        )
        if let result = await task.value {
            return ProcessDetectedResumeIndexes(result)
        }
        return latestCompletedLoadResult.map(ProcessDetectedResumeIndexes.init)
    }

    /// Returns the newest completed coordinated capture immediately on the main actor.
    func cachedResumeIndexes() -> ProcessDetectedResumeIndexes? {
        latestCompletedLoadResult.map(ProcessDetectedResumeIndexes.init)
    }

    /// Returns the newest completed coordinated capture and schedules a refresh if stale.
    func currentResumeIndexesSchedulingRefresh() -> ProcessDetectedResumeIndexes? {
        scheduleRefreshIfStale()
        return cachedResumeIndexes()
    }

    func scheduleRefreshIfStale(
        validating panelKey: RestorableAgentSessionIndex.PanelKey? = nil
    ) {
        _ = refreshTaskIfStale(validating: panelKey)
    }

    func refreshForkAvailabilityNow(workspaceId: UUID? = nil, panelId: UUID? = nil) async {
        ensureWatchingHookStoreDirectory()
        var panelKey: PanelKey?
        if let workspaceId, let panelId {
            panelKey = PanelKey(workspaceId: workspaceId, panelId: panelId)
        }
        let task = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .workspace,
            validating: panelKey
        )
        _ = await task.value
    }

    private func refreshTaskIfStale(validating panelKey: PanelKey? = nil) -> Task<LoadResult?, Never>? {
        ensureWatchingHookStoreDirectory()
        let freshestCompletedAt = if panelKey == nil {
            [loadedAt, latestCompletedAt].compactMap { $0 }.max()
        } else {
            loadedAt
        }
        if let freshestCompletedAt,
           dateProvider().timeIntervalSince(freshestCompletedAt) < Self.cacheTTL {
            return nil
        }
        return requestRefresh(
            freshness: panelKey == nil ? .joinCurrentGeneration : .captureAfterRequest,
            publication: .workspace,
            validating: panelKey
        )
    }

    private func requestForkAvailabilityRefresh(validating panelKey: PanelKey) {
        ensureWatchingHookStoreDirectory()
        _ = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .workspace,
            validating: panelKey
        )
    }

    func startBackgroundRefresh() {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        _ = requestRefresh(
            freshness: .joinCurrentGeneration,
            publication: .workspace,
            validating: nil
        )
    }

    func invalidatePublishedForkValidations() {
        validatedForkPanels.removeAll()
        validatedForkPanelProbeCompletedAt.removeAll()
        validatedMissingForkPanels.removeAll()
    }

    func applyReloadedResult(
        _ result: LoadResult,
        validationPanelsByPanelID: [UUID: PanelKey],
        generationID: UUID
    ) {
        let loadedAt = dateProvider()
        applyReloadedIndex(
            result.index,
            loadedAt: loadedAt,
            liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
            processScopeFingerprint: result.processScopeFingerprint,
            forkValidatedPanels: result.forkValidatedPanels
        )
        applyForkValidations(
            validationPanelsByPanelID,
            from: result.index,
            generationID: generationID,
            completedAt: loadedAt
        )
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        loadedAt: Date,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    ) {
        index = newIndex
        self.loadedAt = loadedAt
        validatedForkPanels = forkValidatedPanels
        validatedForkPanelProbeCompletedAt = forkPanelProbeTimestamps(
            for: forkValidatedPanels,
            completedAt: loadedAt
        )
        validatedMissingForkPanels.removeAll()
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
    }

    private func applyForkValidations(
        _ validationPanelsByPanelID: [UUID: PanelKey],
        from loadedIndex: RestorableAgentSessionIndex,
        generationID: UUID,
        completedAt: Date
    ) {
        for (panelID, panelKey) in validationPanelsByPanelID
        where pendingForkValidationGenerationByPanelID[panelID] == generationID {
            if loadedIndex.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId) == nil {
                validatedMissingForkPanels[panelKey] = completedAt
            } else if let validationKey = validatedForkPanelKey(for: panelKey) {
                validatedForkPanelProbeCompletedAt[validationKey] = completedAt
            }
            pendingForkValidationGenerationByPanelID.removeValue(forKey: panelID)
        }
    }

    private func forkPanelProbeTimestamps(
        for panelKeys: Set<PanelKey>,
        completedAt: Date
    ) -> [PanelKey: Date] {
        Dictionary(uniqueKeysWithValues: panelKeys.map { ($0, completedAt) })
    }

    private func hasFreshForkAvailabilityProbe(for panelKey: PanelKey) -> Bool {
        guard let completedAt = validatedForkPanelProbeCompletedAt[panelKey] else { return false }
        return dateProvider().timeIntervalSince(completedAt) < Self.forkAvailabilityProbeTTL
    }

    private func validatedForkPanelKey(
        for panelKey: PanelKey
    ) -> PanelKey? {
        if validatedForkPanels.contains(panelKey) {
            return panelKey
        }
        return validatedForkPanels.first { $0.panelId == panelKey.panelId }
    }

    func handleHookStoreChange() {
        if refreshTailID != nil {
            changePending = true
            drainPendingHookStoreChangeIfPossible()
            return
        }
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startBackgroundRefresh()
        } else if deferredReloadTimer == nil {
            // DispatchSourceTimer coalesces hook-store event bursts without Task.sleep in runtime code.
            let timer = DispatchSource.makeTimerSource(queue: watchQueue)
            timer.schedule(deadline: .now() + (Self.minEventReloadInterval - elapsed))
            timer.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.deferredReloadTimer?.cancel()
                    self.deferredReloadTimer = nil
                    self.handleHookStoreChange()
                }
            }
            deferredReloadTimer = timer
            timer.resume()
        }
    }

    private func ensureWatchingHookStoreDirectory() {
        guard directoryWatchSource == nil else { return }
        let dir = hookStoreDirectoryProvider()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        // DispatchSource is the platform file-watch bridge; events re-enter MainActor.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleHookStoreChange() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directoryWatchSource = source
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
