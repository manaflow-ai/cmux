import Darwin
import Foundation

struct HookStoreFileStamp: Equatable, Sendable {
    let filename: String
    let deviceID: UInt64
    let inode: UInt64
    let size: Int64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
}

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
    private var pendingForkFallbackSnapshots: [ForkProbeKey: SessionRestorableAgentSnapshot] = [:]
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?
    private var hookStoreInputStamp: [HookStoreFileStamp]?
    private var hookStoreInputStampObservedDuringInitialLoad: [HookStoreFileStamp]?
    private var latestCompletedLoadWorkloadCount = 0
    private var latestCompletedLiveAgentProcessCount = 0

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    // Scale event-driven reloads so the measured ~350ms-1.8s loader cannot
    // approach continuous duty cycle as indexed history or live-agent work grows.
    private static let minEventReloadInterval: TimeInterval = 5.0
    private static let maxEventReloadInterval: TimeInterval = 30.0
    // Reach the cap near the profiled large-history fixtures, not at modest history sizes.
    private static let historyRecordsPerReloadIntervalStep = 45
    private static let liveAgentsPerReloadIntervalStep = 11

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let forkSupportProvider: @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        forkSupportProvider: @escaping @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool = {
            snapshot,
            isRemoteContext in
            await Task.detached(priority: .utility) {
                await AgentForkSupport.supportsFork(
                    snapshot: snapshot,
                    isRemoteContext: isRemoteContext
                )
            }.value
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
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.isSupported == false
    }

    func forkSupportProbeAccepted(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.isSupported == true
    }

    private func forkSupportValidation(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool,
        fallbackSnapshot: SessionRestorableAgentSnapshot?
    ) -> ForkSupportValidation? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let snapshot = fallbackSnapshot ?? index?.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        let validationKey = validatedForkPanelKey(for: panelKey) ?? panelKey
        let probeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        guard hasFreshForkAvailabilityProbe(for: probeKey, snapshot: snapshot) else { return nil }
        return validatedForkSupport[probeKey]
    }

    func prepareForkAvailabilityProbe(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let probeKey = ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
        scheduleRefreshIfStale(validating: panelKey, isRemoteContext: isRemoteContext)
        guard let index else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        guard let snapshot = fallbackSnapshot ?? index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        guard let validationKey = validatedForkPanelKey(for: panelKey) ?? (fallbackSnapshot == nil ? nil : panelKey) else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        let resolvedProbeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        guard hasFreshForkAvailabilityProbe(for: resolvedProbeKey, snapshot: snapshot) else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        return true
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func currentAutosaveCacheSchedulingRefresh() -> ProcessDetectedResumeIndexes.AutosaveAgentIndexCache? {
        scheduleRefreshIfStale()
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil,
              !changePending,
              deferredReloadTimer == nil,
              let index else {
            return nil
        }
        return ProcessDetectedResumeIndexes.AutosaveAgentIndexCache(
            restorableAgentIndex: index,
            processScopeFingerprint: processScopeFingerprint
        )
    }

    func requestRefreshForAutosaveProcessScopeMismatch() {
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil,
              deferredReloadTimer == nil else {
            return
        }
        startReload()
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
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) async {
        if let workspaceId, let panelId {
            let probeKey = ForkProbeKey(
                panelKey: RestorableAgentSessionIndex.PanelKey(
                    workspaceId: workspaceId,
                    panelId: panelId
                ),
                isRemoteContext: isRemoteContext
            )
            pendingForkValidationPanels.insert(probeKey)
            if let fallbackSnapshot {
                pendingForkFallbackSnapshots[probeKey] = fallbackSnapshot
            }
        }
        _ = await reloadIfLiveAgentProcessFingerprintChanged()
    }

    private func requestForkAvailabilityRefresh(
        validating probeKey: ForkProbeKey,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) {
        pendingForkValidationPanels.insert(probeKey)
        if let fallbackSnapshot {
            pendingForkFallbackSnapshots[probeKey] = fallbackSnapshot
        }
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
        let initialHookStoreDirectory = hookStoreInputStamp == nil
            ? hookStoreDirectoryProvider()
            : nil
        let (result, initialHookStoreInputStamp) = await Task.detached(priority: .utility) {
            let initialHookStoreInputStamp = initialHookStoreDirectory.map {
                Self.hookStoreInputStamp(in: $0)
            }
            return (indexLoader(), initialHookStoreInputStamp)
        }.value
        guard !Task.isCancelled else { return }
        if hookStoreInputStamp == nil {
            let observedInputStamp = hookStoreInputStampObservedDuringInitialLoad
            hookStoreInputStamp = observedInputStamp ?? initialHookStoreInputStamp
            if let initialHookStoreInputStamp,
               let observedInputStamp,
               observedInputStamp != initialHookStoreInputStamp {
                changePending = true
            }
            hookStoreInputStampObservedDuringInitialLoad = nil
        }
        let loadedAt = dateProvider()
        latestCompletedLoadWorkloadCount = result.index.loadWorkloadCount
        latestCompletedLiveAgentProcessCount = result.index.liveAgentProcessCount
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
        index = newIndex
        self.loadedAt = loadedAt
        validatedForkPanels = forkValidatedPanels
        validatedMissingForkPanels.removeAll()
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
    }

    private func applyPendingForkValidations() async {
        let pendingProbeKeys = pendingForkValidationPanels
        let fallbackSnapshots = pendingForkFallbackSnapshots
        pendingForkValidationPanels.removeAll()
        pendingForkFallbackSnapshots.removeAll()
        guard let index else {
            return
        }
        for probeKey in pendingProbeKeys {
            let panelKey = probeKey.panelKey
            let fallbackSnapshot = fallbackSnapshots[probeKey]
            let snapshot = fallbackSnapshot ?? index.snapshot(
                workspaceId: panelKey.workspaceId,
                panelId: panelKey.panelId
            )
            if snapshot == nil {
                validatedMissingForkPanels[panelKey] = dateProvider()
            } else if let validationKey = validatedForkPanelKey(for: panelKey)
                        ?? (fallbackSnapshot == nil ? nil : panelKey),
                      let snapshot {
                let resolvedProbeKey = ForkProbeKey(
                    panelKey: validationKey,
                    isRemoteContext: probeKey.isRemoteContext
                )
                if let command = snapshot.forkCommand {
                    let isSupported = await forkSupportProvider(
                        snapshot,
                        probeKey.isRemoteContext
                    )
                    validatedForkSupport[resolvedProbeKey] = ForkSupportValidation(
                        command: command,
                        isSupported: isSupported,
                        completedAt: dateProvider()
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
            liveAgentCount: latestCompletedLiveAgentProcessCount,
            historyWorkloadCount: latestCompletedLoadWorkloadCount
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
            let currentStamp = Self.hookStoreInputStamp(in: dir)
            Task { @MainActor in self?.handleHookStoreDirectoryEvent(currentStamp) }
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

    func handleHookStoreDirectoryEvent(_ currentStamp: [HookStoreFileStamp]) {
        guard let baselineStamp = hookStoreInputStamp else {
            hookStoreInputStampObservedDuringInitialLoad = currentStamp
            return
        }
        guard currentStamp != baselineStamp else { return }
        hookStoreInputStamp = currentStamp
        handleHookStoreChange()
    }

    nonisolated private static func hookStoreInputStamp(in directory: String) -> [HookStoreFileStamp] {
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        return filenames
            .filter { $0.hasSuffix("-hook-sessions.json") }
            .sorted()
            .compactMap { filename -> HookStoreFileStamp? in
                let path = directoryURL
                    .appendingPathComponent(filename, isDirectory: false)
                    .path
                var info = stat()
                guard stat(path, &info) == 0 else { return nil }
                return HookStoreFileStamp(
                    filename: filename,
                    deviceID: UInt64(info.st_dev),
                    inode: UInt64(info.st_ino),
                    size: Int64(info.st_size),
                    modificationTimeSeconds: Int64(info.st_mtimespec.tv_sec),
                    modificationTimeNanoseconds: Int64(info.st_mtimespec.tv_nsec)
                )
            }
    }

    private static func hookEventReloadInterval(
        liveAgentCount: Int,
        historyWorkloadCount: Int
    ) -> TimeInterval {
        let intervalSteps = max(
            1,
            max(
                reloadIntervalSteps(
                    workloadCount: historyWorkloadCount,
                    unitsPerStep: historyRecordsPerReloadIntervalStep
                ),
                reloadIntervalSteps(
                    workloadCount: liveAgentCount,
                    unitsPerStep: liveAgentsPerReloadIntervalStep
                )
            )
        )
        return min(
            maxEventReloadInterval,
            minEventReloadInterval * TimeInterval(intervalSteps)
        )
    }

    private static func reloadIntervalSteps(
        workloadCount: Int,
        unitsPerStep: Int
    ) -> Int {
        let workloadCount = max(0, workloadCount)
        return workloadCount / unitsPerStep
            + (workloadCount.isMultiple(of: unitsPerStep) ? 0 : 1)
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
