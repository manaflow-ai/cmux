import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private struct ForkValidationKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
        let kind: RestorableAgentKind
        let sessionId: String

        init(workspaceId: UUID, panelId: UUID, snapshot: SessionRestorableAgentSnapshot) {
            self.workspaceId = workspaceId
            self.panelId = panelId
            self.kind = snapshot.kind
            self.sessionId = snapshot.sessionId
        }
    }

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var forkAvailabilityProbeCompletedAt: Date?
    private var validatedForkSnapshots = Set<ForkValidationKey>()
    private var validatedMissingForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var pendingForkValidationPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTask: Task<Void, Never>?

    private static let cacheTTL: TimeInterval = 60.0
    private static let minEventReloadInterval: TimeInterval = 2.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date
    private let processIsRunningProvider: @MainActor (Int) -> Bool

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        },
        processIsRunningProvider: @escaping @MainActor (Int) -> Bool = { processId in
            guard processId > 0, processId <= Int(Int32.max) else { return false }
            let result = Darwin.kill(pid_t(processId), 0)
            return result == 0 || errno == EPERM
        }
    ) {
        self.indexLoader = indexLoader
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
        self.processIsRunningProvider = processIsRunningProvider
    }

    deinit {
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
        deferredReloadTask?.cancel()
        directoryWatchSource?.cancel()
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for the Fork Conversation context menu. Never blocks.
    func snapshotForForkAvailability(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        guard hasCompletedForkAvailabilityProbe,
              !isForkAvailabilityRefreshInFlight,
              let index else {
            return nil
        }
        guard let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        let processIDs = index.processIDs(workspaceId: workspaceId, panelId: panelId)
        guard cachedLiveProcessIDsAreRunning(processIDs) else {
            return nil
        }
        if processIDs.isEmpty,
           !validatedForkSnapshots.contains(
               ForkValidationKey(workspaceId: workspaceId, panelId: panelId, snapshot: snapshot)
           ) {
            return nil
        }
        return snapshot
    }

    func prepareForkAvailabilityProbe(workspaceId: UUID, panelId: UUID) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        scheduleRefreshIfStale()
        guard !isForkAvailabilityRefreshInFlight else {
            return false
        }
        guard let index else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            if validatedMissingForkPanels.contains(panelKey), hasFreshForkAvailabilityProbe {
                return true
            }
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        let processIDs = index.processIDs(workspaceId: workspaceId, panelId: panelId)
        guard cachedLiveProcessIDsAreRunning(processIDs) else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        if processIDs.isEmpty,
           !validatedForkSnapshots.contains(
               ForkValidationKey(workspaceId: workspaceId, panelId: panelId, snapshot: snapshot)
           ) {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard hasFreshForkAvailabilityProbe else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        return !isForkAvailabilityRefreshInFlight
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func scheduleRefreshIfStale() {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else { return }
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        startReload()
    }

    func refreshForkAvailabilityNow(workspaceId: UUID? = nil, panelId: UUID? = nil) async {
        if let workspaceId, let panelId {
            pendingForkValidationPanels.insert(
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            )
        }
        if await reloadIfLiveAgentProcessFingerprintChanged() {
            forkAvailabilityProbeCompletedAt = dateProvider()
        }
    }

    private func requestForkAvailabilityRefresh(validating panelKey: RestorableAgentSessionIndex.PanelKey) {
        pendingForkValidationPanels.insert(panelKey)
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.reloadIfLiveAgentProcessFingerprintChanged() {
                self.forkAvailabilityProbeCompletedAt = self.dateProvider()
            }
            self.forkAvailabilityRefreshTask = nil
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func startReload() {
        deferredReloadTask?.cancel()
        deferredReloadTask = nil
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
        let result = await Task.detached(priority: .utility) {
            indexLoader()
        }.value
        guard !Task.isCancelled else { return }
        let loadedAt = dateProvider()
        if forcePublish
            || result.liveAgentProcessFingerprint != liveAgentProcessFingerprint
            || result.processScopeFingerprint != processScopeFingerprint {
            applyReloadedIndex(
                result.index,
                loadedAt: loadedAt,
                liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
                processScopeFingerprint: result.processScopeFingerprint
            )
        } else {
            self.loadedAt = loadedAt
            self.processScopeFingerprint = result.processScopeFingerprint
        }
        applyPendingForkValidations()
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        loadedAt: Date,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>
    ) {
        index = newIndex
        self.loadedAt = loadedAt
        self.forkAvailabilityProbeCompletedAt = loadedAt
        validatedForkSnapshots.removeAll()
        validatedMissingForkPanels.removeAll()
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
    }

    private func applyPendingForkValidations() {
        guard let index else {
            pendingForkValidationPanels.removeAll()
            return
        }
        for panelKey in pendingForkValidationPanels {
            if let snapshot = index.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId) {
                validatedForkSnapshots.insert(
                    ForkValidationKey(
                        workspaceId: panelKey.workspaceId,
                        panelId: panelKey.panelId,
                        snapshot: snapshot
                    )
                )
            } else {
                validatedMissingForkPanels.insert(panelKey)
            }
        }
        pendingForkValidationPanels.removeAll()
    }

    private var hasFreshForkAvailabilityProbe: Bool {
        guard let forkAvailabilityProbeCompletedAt else { return false }
        return dateProvider().timeIntervalSince(forkAvailabilityProbeCompletedAt) < Self.cacheTTL
    }

    private var hasCompletedForkAvailabilityProbe: Bool {
        forkAvailabilityProbeCompletedAt != nil
    }

    private var isForkAvailabilityRefreshInFlight: Bool {
        refreshTask != nil || forkAvailabilityRefreshTask != nil
    }

    private func cachedLiveProcessIDsAreRunning(_ processIDs: Set<Int>) -> Bool {
        for processID in processIDs {
            guard processIsRunningProvider(processID) else { return false }
        }
        return true
    }

    private func handleHookStoreChange() {
        if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
        } else if deferredReloadTask == nil {
            let wait = Self.minEventReloadInterval - elapsed
            deferredReloadTask = Task { @MainActor [weak self] in
                // Bounded, cancellable delay to honor the reload floor after hook-store events.
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.deferredReloadTask = nil
                self.handleHookStoreChange()
            }
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
