import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private struct ForkProbeKey: Hashable {
        let panelKey: RestorableAgentSessionIndex.PanelKey
        let isRemoteContext: Bool
    }

    private struct ForkSupportValidation {
        let command: String
        let isSupported: Bool
        let completedAt: Date
    }

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var validatedForkSupport: [ForkProbeKey: ForkSupportValidation] = [:]
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var pendingForkValidationPanels = Set<ForkProbeKey>()
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0
    private static let maxEventReloadInterval: TimeInterval = 30.0
    private static let liveAgentsPerReloadIntervalStep = 8

    static func hookEventReloadInterval(liveAgentCount: Int) -> TimeInterval {
        let clampedAgentCount = max(0, liveAgentCount)
        let intervalSteps = max(
            1,
            (clampedAgentCount + liveAgentsPerReloadIntervalStep - 1) / liveAgentsPerReloadIntervalStep
        )
        return min(
            maxEventReloadInterval,
            TimeInterval(intervalSteps) * minEventReloadInterval
        )
    }

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    /// Loaders must move synchronous CPU and file-I/O work off the main actor
    /// before their first suspension point. This owner awaits the closure directly.
    private let indexLoader: @Sendable () async -> SharedLiveAgentIndexLoader.LoadResult
    private let forkSupportProvider: @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date

    init(
        indexLoader: @escaping @Sendable () async -> SharedLiveAgentIndexLoader.LoadResult = {
            let processSnapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
                requirements: [.processDetails, .cmuxScope],
                maximumAge: 3,
                consumer: .sharedLiveAgentIndex
            )
            return await Task.detached(priority: .utility) {
                SharedLiveAgentIndexLoader(
                    processSnapshotProvider: { processSnapshot }
                ).loadResultSynchronously()
            }.value
        },
        forkSupportProvider: @escaping @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool = {
            snapshot,
            isRemoteContext in
            await AgentForkSupport.supportsFork(snapshot: snapshot, isRemoteContext: isRemoteContext)
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        }
    ) {
        self.indexLoader = indexLoader
        self.forkSupportProvider = forkSupportProvider
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
    }

    deinit {
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
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
    func snapshotForForkAvailability(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false
    ) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let validationKey = validatedForkPanelKey(for: panelKey),
              let index,
              let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId),
              hasFreshForkAvailabilityProbe(
                for: ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext),
                snapshot: snapshot
              ),
              validatedForkSupport[
                ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
              ]?.isSupported == true else {
            return nil
        }
        return snapshot
    }

    func forkSupportProbeRejected(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false
    ) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let validationKey = validatedForkPanelKey(for: panelKey),
              let snapshot = index?.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            return false
        }
        let probeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        return hasFreshForkAvailabilityProbe(for: probeKey, snapshot: snapshot)
            && validatedForkSupport[probeKey]?.isSupported == false
    }

    func prepareForkAvailabilityProbe(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false
    ) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let probeKey = ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
        scheduleRefreshIfStale(validating: panelKey, isRemoteContext: isRemoteContext)
        guard let index else {
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        guard let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        guard let validationKey = validatedForkPanelKey(for: panelKey) else {
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        let resolvedProbeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        guard hasFreshForkAvailabilityProbe(for: resolvedProbeKey, snapshot: snapshot) else {
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        return true
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func scheduleRefreshIfStale(
        validating panelKey: RestorableAgentSessionIndex.PanelKey? = nil,
        isRemoteContext: Bool = false
    ) {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else {
            if let panelKey {
                pendingForkValidationPanels.insert(
                    ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
                )
            }
            return
        }
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        if let panelKey {
            pendingForkValidationPanels.insert(
                ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
            )
        }
        startReload()
    }

    func refreshForkAvailabilityNow(
        workspaceId: UUID? = nil,
        panelId: UUID? = nil,
        isRemoteContext: Bool = false
    ) async {
        if let workspaceId, let panelId {
            pendingForkValidationPanels.insert(
                ForkProbeKey(
                    panelKey: RestorableAgentSessionIndex.PanelKey(
                        workspaceId: workspaceId,
                        panelId: panelId
                    ),
                    isRemoteContext: isRemoteContext
                )
            )
        }
        _ = await reloadIfLiveAgentProcessFingerprintChanged()
    }

    private func requestForkAvailabilityRefresh(validating probeKey: ForkProbeKey) {
        pendingForkValidationPanels.insert(probeKey)
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func startReload() {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reload(forcePublish: true)
            self.refreshTask = nil
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
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

    private func reload(forcePublish: Bool) async {
        let indexLoader = self.indexLoader
        let result = await indexLoader()
        guard !Task.isCancelled else { return }
        let loadedAt = dateProvider()
        let hasPendingForkValidations = !pendingForkValidationPanels.isEmpty
        if forcePublish
            || hasPendingForkValidations
            || result.liveAgentProcessFingerprint != liveAgentProcessFingerprint
            || result.processScopeFingerprint != processScopeFingerprint {
            applyReloadedIndex(
                result.index,
                loadedAt: loadedAt,
                liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
                processScopeFingerprint: result.processScopeFingerprint,
                forkValidatedPanels: result.forkValidatedPanels
            )
        } else {
            self.loadedAt = loadedAt
            self.processScopeFingerprint = result.processScopeFingerprint
            self.validatedForkPanels = result.forkValidatedPanels
        }
        await applyPendingForkValidations()
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        loadedAt: Date,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    ) {
#if DEBUG
        let applyMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
            .restorableApply,
            inputCount: newIndex.forkValidationEntries().count
        )
#endif
        index = newIndex
        self.loadedAt = loadedAt
        validatedForkPanels = forkValidatedPanels
        validatedMissingForkPanels.removeAll()
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
#if DEBUG
        ProcessPerformanceMetrics.shared.operationCompleted(
            applyMetricsToken,
            outputCount: newIndex.forkValidationEntries().count
        )
#endif
    }

    private func applyPendingForkValidations() async {
        let pendingProbeKeys = pendingForkValidationPanels
        pendingForkValidationPanels.removeAll()
        guard let index else {
            return
        }
        let now = dateProvider()
        for probeKey in pendingProbeKeys {
            let panelKey = probeKey.panelKey
            if index.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId) == nil {
                validatedMissingForkPanels[panelKey] = now
            } else if let validationKey = validatedForkPanelKey(for: panelKey),
                      let snapshot = index.snapshot(
                        workspaceId: panelKey.workspaceId,
                        panelId: panelKey.panelId
                      ) {
                let resolvedProbeKey = ForkProbeKey(
                    panelKey: validationKey,
                    isRemoteContext: probeKey.isRemoteContext
                )
                if let command = snapshot.forkCommand {
                    validatedForkSupport[resolvedProbeKey] = ForkSupportValidation(
                        command: command,
                        isSupported: await forkSupportProvider(snapshot, probeKey.isRemoteContext),
                        completedAt: now
                    )
                } else {
                    validatedForkSupport.removeValue(forKey: resolvedProbeKey)
                }
            }
        }
    }

    private func hasFreshForkAvailabilityProbe(
        for probeKey: ForkProbeKey,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let validation = validatedForkSupport[probeKey],
              validation.command == snapshot.forkCommand else {
            return false
        }
        return dateProvider().timeIntervalSince(validation.completedAt) < Self.forkAvailabilityProbeTTL
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
        let reloadInterval = Self.hookEventReloadInterval(
            liveAgentCount: liveAgentProcessFingerprint.count
        )
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= reloadInterval {
            startReload()
        } else if deferredReloadTimer == nil {
            // DispatchSourceTimer coalesces hook-store event bursts without Task.sleep in runtime code.
            let timer = DispatchSource.makeTimerSource(queue: watchQueue)
            timer.schedule(deadline: .now() + (reloadInterval - elapsed))
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
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
