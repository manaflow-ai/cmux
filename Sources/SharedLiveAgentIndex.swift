import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    struct LoadBoundary: Sendable {
        fileprivate let sequence: UInt64
    }

    private struct InFlightLoad {
        let sequence: UInt64
        let task: Task<SharedLiveAgentIndexLoader.LoadResult, Never>
        var forcePublish: Bool
        var notifyObservers: Bool
    }

    private struct LoadOutcome {
        let sequence: UInt64
        let result: SharedLiveAgentIndexLoader.LoadResult
    }

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var nextLoadSequence: UInt64 = 0
    private var lastAppliedLoadSequence: UInt64 = 0
    private var inFlightLoad: InFlightLoad?
    private var validatedForkPanelProbeCompletedAt: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var pendingForkValidationPanels = Set<RestorableAgentSessionIndex.PanelKey>()
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
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
        inFlightLoad?.task.cancel()
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
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let index,
              validatedForkPanelKey(for: panelKey) != nil else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for an enabled Fork Conversation action. Never blocks.
    func snapshotForForkAvailability(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let validationKey = validatedForkPanelKey(for: panelKey),
              hasFreshForkAvailabilityProbe(for: validationKey),
              let index else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    func prepareForkAvailabilityProbe(workspaceId: UUID, panelId: UUID) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        scheduleRefreshIfStale(validating: panelKey)
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

    /// Captures the most recently started physical load. A later safety-critical
    /// request can require a scan that starts after this boundary.
    func markLoadBoundary() -> LoadBoundary {
        LoadBoundary(sequence: nextLoadSequence)
    }

    /// Returns an index from a physical load that starts after this request.
    func refreshedIndex() async -> RestorableAgentSessionIndex {
        let boundary = markLoadBoundary()
        return await reload(
            forcePublish: true,
            startedAfter: boundary,
            continueFreshnessAfterCancellation: false
        )
    }

    /// Returns an index from a physical load that began after `boundary`.
    /// Concurrent callers waiting behind the same older load share one successor.
    func indexLoaded(after boundary: LoadBoundary) async -> RestorableAgentSessionIndex {
        await reload(forcePublish: true, startedAfter: boundary)
    }

    /// Shares the same process snapshot and physical index load with autosave callers.
    func processDetectedResumeIndexes() async -> ProcessDetectedResumeIndexes {
        let boundary = markLoadBoundary()
        let outcome = await coordinatedLoad(
            forcePublish: false,
            notifyObservers: false,
            startedAfter: boundary,
            continueFreshnessAfterCancellation: false
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: outcome.result.index,
            surfaceResumeBindingIndex: outcome.result.surfaceResumeBindingIndex
        )
    }

    func scheduleRefreshIfStale(validating panelKey: RestorableAgentSessionIndex.PanelKey? = nil) {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else {
            if let panelKey {
                pendingForkValidationPanels.insert(panelKey)
            }
            return
        }
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        if let panelKey {
            pendingForkValidationPanels.insert(panelKey)
        }
        startReload()
    }

    func refreshForkAvailabilityNow(workspaceId: UUID? = nil, panelId: UUID? = nil) async {
        if let workspaceId, let panelId {
            pendingForkValidationPanels.insert(
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            )
        }
        _ = await reloadIfLiveAgentProcessFingerprintChanged()
    }

    private func requestForkAvailabilityRefresh(validating panelKey: RestorableAgentSessionIndex.PanelKey) {
        pendingForkValidationPanels.insert(panelKey)
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func startReload(startedAfter boundary: LoadBoundary? = nil) {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reload(forcePublish: true, startedAfter: boundary)
            self.refreshTask = nil
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func reloadIfLiveAgentProcessFingerprintChanged() async -> Bool {
        guard refreshTask == nil else {
            changePending = true
            return false
        }
        await reload(forcePublish: index == nil)
        return true
    }

    @discardableResult
    private func reload(
        forcePublish: Bool,
        startedAfter boundary: LoadBoundary? = nil,
        continueFreshnessAfterCancellation: Bool = true
    ) async -> RestorableAgentSessionIndex {
        let outcome = await coordinatedLoad(
            forcePublish: forcePublish,
            notifyObservers: true,
            startedAfter: boundary,
            continueFreshnessAfterCancellation: continueFreshnessAfterCancellation
        )
        return outcome.result.index
    }

    private func coordinatedLoad(
        forcePublish: Bool,
        notifyObservers: Bool,
        startedAfter boundary: LoadBoundary? = nil,
        continueFreshnessAfterCancellation: Bool
    ) async -> LoadOutcome {
        while true {
            if let inFlightLoad {
                let satisfiesBoundary = boundary.map { inFlightLoad.sequence > $0.sequence } ?? true
                if satisfiesBoundary, forcePublish {
                    self.inFlightLoad?.forcePublish = true
                }
                if satisfiesBoundary, notifyObservers {
                    self.inFlightLoad?.notifyObservers = true
                }
                let outcome = await finish(inFlightLoad)
                if Task.isCancelled, !continueFreshnessAfterCancellation {
                    return outcome
                }
                if satisfiesBoundary {
                    return outcome
                }
                continue
            }

            nextLoadSequence = nextLoadSequence &+ 1
            let sequence = nextLoadSequence
            let indexLoader = self.indexLoader
            let task = Task.detached(priority: .utility) {
#if DEBUG
                let startedAt = ProcessInfo.processInfo.systemUptime
                cmuxDebugLog("agentIndex.load.started sequence=\(sequence)")
#endif
                let result = indexLoader()
#if DEBUG
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                let elapsed = String(format: "%.1f", elapsedMs)
                cmuxDebugLog("agentIndex.load.finished sequence=\(sequence) elapsedMs=\(elapsed)")
#endif
                return result
            }
            inFlightLoad = InFlightLoad(
                sequence: sequence,
                task: task,
                forcePublish: forcePublish,
                notifyObservers: notifyObservers
            )
        }
    }

    private func finish(_ load: InFlightLoad) async -> LoadOutcome {
        let result = await load.task.value
        let outcome = LoadOutcome(sequence: load.sequence, result: result)
        if let currentLoad = inFlightLoad,
           currentLoad.sequence == load.sequence {
            inFlightLoad = nil
            let didPublishIndex = apply(outcome, forcePublish: currentLoad.forcePublish)
            if currentLoad.notifyObservers || didPublishIndex {
                NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            }
        }
        return outcome
    }

    private func apply(_ outcome: LoadOutcome, forcePublish: Bool) -> Bool {
        guard outcome.sequence >= lastAppliedLoadSequence else { return false }
        lastAppliedLoadSequence = outcome.sequence
        let result = outcome.result
        let loadedAt = dateProvider()
        let hasPendingForkValidations = !pendingForkValidationPanels.isEmpty
        let indexWasMissing = index == nil
        let liveAgentFingerprintChanged = result.liveAgentProcessFingerprint != liveAgentProcessFingerprint
        let processScopeFingerprintChanged = result.processScopeFingerprint != processScopeFingerprint
        let forkValidatedPanelsChanged = result.forkValidatedPanels != validatedForkPanels
        let observableStateChanged = indexWasMissing
            || liveAgentFingerprintChanged
            || forkValidatedPanelsChanged
            || hasPendingForkValidations
        if indexWasMissing
            || forcePublish
            || hasPendingForkValidations
            || liveAgentFingerprintChanged
            || processScopeFingerprintChanged {
            applyReloadedIndex(
                result.index,
                loadedAt: loadedAt,
                liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
                processScopeFingerprint: result.processScopeFingerprint,
                forkValidatedPanels: result.forkValidatedPanels
            )
            applyPendingForkValidations()
            return observableStateChanged
        } else {
            self.loadedAt = loadedAt
            self.processScopeFingerprint = result.processScopeFingerprint
            self.validatedForkPanels = result.forkValidatedPanels
            self.validatedForkPanelProbeCompletedAt = forkPanelProbeTimestamps(
                for: result.forkValidatedPanels,
                completedAt: loadedAt
            )
        }
        applyPendingForkValidations()
        return observableStateChanged
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

    private func applyPendingForkValidations() {
        guard let index else {
            pendingForkValidationPanels.removeAll()
            return
        }
        let now = dateProvider()
        for panelKey in pendingForkValidationPanels {
            if index.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId) == nil {
                validatedMissingForkPanels[panelKey] = now
            } else if let validationKey = validatedForkPanelKey(for: panelKey) {
                validatedForkPanelProbeCompletedAt[validationKey] = now
            }
        }
        pendingForkValidationPanels.removeAll()
    }

    private func forkPanelProbeTimestamps(
        for panelKeys: Set<RestorableAgentSessionIndex.PanelKey>,
        completedAt: Date
    ) -> [RestorableAgentSessionIndex.PanelKey: Date] {
        Dictionary(uniqueKeysWithValues: panelKeys.map { ($0, completedAt) })
    }

    private func hasFreshForkAvailabilityProbe(for panelKey: RestorableAgentSessionIndex.PanelKey) -> Bool {
        guard let completedAt = validatedForkPanelProbeCompletedAt[panelKey] else { return false }
        return dateProvider().timeIntervalSince(completedAt) < Self.forkAvailabilityProbeTTL
    }

    private func validatedForkPanelKey(
        for panelKey: RestorableAgentSessionIndex.PanelKey
    ) -> RestorableAgentSessionIndex.PanelKey? {
        if validatedForkPanels.contains(panelKey) {
            return panelKey
        }
        return validatedForkPanels.first { $0.panelId == panelKey.panelId }
    }

    private var isForkAvailabilityRefreshInFlight: Bool {
        refreshTask != nil || forkAvailabilityRefreshTask != nil
    }

    private func handleHookStoreChange() {
        if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
            return
        }
        if inFlightLoad != nil {
            startReload(startedAfter: markLoadBoundary())
            return
        }
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
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
        if refreshTask != nil {
            changePending = true
        } else if inFlightLoad != nil {
            startReload(startedAfter: markLoadBoundary())
        } else {
            startReload()
        }
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
