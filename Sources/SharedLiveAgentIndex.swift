import Combine
import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex: ObservableObject {
    static let shared = SharedLiveAgentIndex()

    @Published private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var forkAvailabilityProbeCompletedAt: Date?
    private var changePending = false
    private var deferredReloadTask: Task<Void, Never>?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 5.0
    private static let minEventReloadInterval: TimeInterval = 2.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> RestorableAgentSessionIndex
    private let hookStoreDirectoryProvider: @MainActor () -> String

    init(
        indexLoader: @escaping @Sendable () -> RestorableAgentSessionIndex = {
            SharedLiveAgentIndexLoader().loadSynchronously()
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        }
    ) {
        self.indexLoader = indexLoader
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
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
        scheduleRefreshIfStale()
        guard forkAvailabilityProbeCompletedAt != nil else {
            requestForkAvailabilityRefresh()
            return nil
        }
        requestForkAvailabilityRefresh()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func scheduleRefreshIfStale() {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        startReload()
    }

    func refreshForkAvailabilityNow() async {
        if await reloadIfLiveAgentProcessFingerprintChanged() {
            forkAvailabilityProbeCompletedAt = Date()
        }
    }

    private func requestForkAvailabilityRefresh() {
        guard !hasFreshForkAvailabilityProbe else { return }
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.reloadIfLiveAgentProcessFingerprintChanged() {
                self.forkAvailabilityProbeCompletedAt = Date()
            }
            self.forkAvailabilityRefreshTask = nil
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
            let newIndex = indexLoader()
            return ReloadResult(
                index: newIndex,
                liveAgentProcessFingerprint: newIndex.liveAgentProcessFingerprint()
            )
        }.value
        guard !Task.isCancelled else { return }
        if forcePublish || result.liveAgentProcessFingerprint != liveAgentProcessFingerprint {
            applyReloadedIndex(result.index, liveAgentProcessFingerprint: result.liveAgentProcessFingerprint)
        }
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        liveAgentProcessFingerprint: Set<String>
    ) {
        index = newIndex
        loadedAt = Date()
        forkAvailabilityProbeCompletedAt = loadedAt
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
    }

    private var hasFreshForkAvailabilityProbe: Bool {
        guard let forkAvailabilityProbeCompletedAt else { return false }
        return Date().timeIntervalSince(forkAvailabilityProbeCompletedAt) < Self.forkAvailabilityProbeTTL
    }

    private func handleHookStoreChange() {
        if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
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
        if index == nil, refreshTask == nil {
            startReload()
        } else if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
        }
    }

    private struct ReloadResult: Sendable {
        let index: RestorableAgentSessionIndex
        let liveAgentProcessFingerprint: Set<String>
    }
}
