import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private typealias LoadResult = SharedLiveAgentIndexLoader.LoadResult
    private typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private enum RefreshFreshness: Equatable {
        case joinCurrentGeneration
        case captureAfterRequest
    }

    private enum RefreshPublication: Equatable {
        case scoped
        case workspace

        mutating func include(_ other: Self) {
            if other == .workspace {
                self = .workspace
            }
        }
    }

    private struct RefreshGeneration {
        enum Phase: Equatable {
            case queued
            case capturing
        }

        let id: UUID
        var phase: Phase
        var publication: RefreshPublication
        var validationPanels: Set<PanelKey>
    }

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshGenerationsByID: [UUID: RefreshGeneration] = [:]
    private var refreshTasksByID: [UUID: Task<LoadResult?, Never>] = [:]
    private var refreshTailID: UUID?
    private var pendingForkValidationGenerationByPanelID: [UUID: UUID] = [:]
    private var validatedForkPanelProbeCompletedAt: [PanelKey: Date] = [:]
    private var validatedForkPanels = Set<PanelKey>()
    private var validatedMissingForkPanels: [PanelKey: Date] = [:]
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        }
    ) {
        self.indexLoader = indexLoader
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
    }

    deinit {
        for task in refreshTasksByID.values {
            task.cancel()
        }
        deferredReloadTimer?.cancel()
        directoryWatchSource?.cancel()
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
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
        return index
    }

    /// Returns the cached index after awaiting any stale refresh this call schedules.
    func indexRefreshingIfNeeded() async -> RestorableAgentSessionIndex? {
        guard let task = refreshTaskIfStale() else {
            return index
        }
        return await task.value?.index ?? index
    }

    /// Returns a fresh shared result without publishing it to process-wide UI state.
    func refreshedIndexForScopedProbe() async -> RestorableAgentSessionIndex {
        ensureWatchingHookStoreDirectory()
        let task = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        return await task.value?.index ?? .empty
    }

    func scheduleRefreshIfStale(validating panelKey: PanelKey? = nil) {
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
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
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

    private func requestRefresh(
        freshness: RefreshFreshness,
        publication: RefreshPublication,
        validating panelKey: PanelKey?
    ) -> Task<LoadResult?, Never> {
        if let refreshTailID,
           var generation = refreshGenerationsByID[refreshTailID],
           let task = refreshTasksByID[refreshTailID],
           freshness == .joinCurrentGeneration || generation.phase == .queued {
            generation.publication.include(publication)
            if let panelKey {
                generation.validationPanels.insert(panelKey)
                pendingForkValidationGenerationByPanelID[panelKey.panelId] = generation.id
            }
            refreshGenerationsByID[refreshTailID] = generation
            return task
        }

        let predecessor = refreshTailID.flatMap { refreshTasksByID[$0] }
        let generationID = UUID()
        var validationPanels = Set<PanelKey>()
        if let panelKey {
            validationPanels.insert(panelKey)
            pendingForkValidationGenerationByPanelID[panelKey.panelId] = generationID
        }

        refreshGenerationsByID[generationID] = RefreshGeneration(
            id: generationID,
            phase: .queued,
            publication: publication,
            validationPanels: validationPanels
        )
        let task = Task { @MainActor [weak self] () -> LoadResult? in
            _ = await predecessor?.value
            guard let self, !Task.isCancelled else { return nil }
            guard var generation = self.refreshGenerationsByID[generationID] else { return nil }
            generation.phase = .capturing
            self.refreshGenerationsByID[generationID] = generation

            let indexLoader = self.indexLoader
            let result = await Task.detached(priority: .utility) {
                indexLoader()
            }.value
            guard !Task.isCancelled else { return result }
            self.completeRefresh(generationID: generationID, result: result)
            return result
        }
        refreshTasksByID[generationID] = task
        refreshTailID = generationID
        return task
    }

    private func startBackgroundRefresh() {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        _ = requestRefresh(
            freshness: .joinCurrentGeneration,
            publication: .workspace,
            validating: nil
        )
    }

    private func completeRefresh(generationID: UUID, result: LoadResult) {
        guard let generation = refreshGenerationsByID.removeValue(forKey: generationID) else {
            return
        }
        refreshTasksByID.removeValue(forKey: generationID)
        if refreshTailID == generationID {
            refreshTailID = nil
        }

        if generation.publication == .workspace {
            applyReloadedResult(
                result,
                validationPanels: generation.validationPanels,
                generationID: generationID
            )
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
        }

        if refreshTailID == nil, changePending {
            changePending = false
            handleHookStoreChange()
        }
    }

    private func applyReloadedResult(
        _ result: LoadResult,
        validationPanels: Set<PanelKey>,
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
            validationPanels,
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
        _ validationPanels: Set<PanelKey>,
        from loadedIndex: RestorableAgentSessionIndex,
        generationID: UUID,
        completedAt: Date
    ) {
        for panelKey in validationPanels
        where pendingForkValidationGenerationByPanelID[panelKey.panelId] == generationID {
            if loadedIndex.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId) == nil {
                validatedMissingForkPanels[panelKey] = completedAt
            } else if let validationKey = validatedForkPanelKey(for: panelKey) {
                validatedForkPanelProbeCompletedAt[validationKey] = completedAt
            }
            pendingForkValidationGenerationByPanelID.removeValue(forKey: panelKey.panelId)
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

    private func handleHookStoreChange() {
        if refreshTailID != nil {
            changePending = true
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
