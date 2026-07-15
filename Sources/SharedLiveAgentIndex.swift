import Darwin
import Foundation

private struct HookStoreFileStamp: Equatable, Sendable {
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

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var validatedForkPanelProbeCompletedAt: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var pendingForkValidationPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?
    private var hookStoreInputStamp: [HookStoreFileStamp]?
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
            hookStoreInputStamp = initialHookStoreInputStamp
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
            self.validatedForkPanelProbeCompletedAt = forkPanelProbeTimestamps(
                for: result.forkValidatedPanels,
                completedAt: loadedAt
            )
        }
        applyPendingForkValidations()
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

    private func handleHookStoreDirectoryEvent(_ currentStamp: [HookStoreFileStamp]) {
        guard currentStamp != hookStoreInputStamp else { return }
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
