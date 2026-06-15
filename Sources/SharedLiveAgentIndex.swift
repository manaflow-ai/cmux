import CMUXAgentLaunch
import Combine
import Darwin
import Foundation

/// Process-wide cache for fork availability and close-history snapshots.
/// Loading does disk reads plus process scans, so refreshes run off-main and menu callers
/// read the cached snapshot synchronously. A hook-store watcher provides freshness and
/// `ObservableObject` lets workspaces re-render when the cache changes.
@MainActor
final class SharedLiveAgentIndex: ObservableObject {
    static let shared = SharedLiveAgentIndex()

    @Published private(set) var index: RestorableAgentSessionIndex?
    private let indexDidChangeSubject = PassthroughSubject<Void, Never>()
    var indexDidChangePublisher: AnyPublisher<Void, Never> {
        indexDidChangeSubject.eraseToAnyPublisher()
    }

    private var loadedAt: Date?
    private var refreshTask: Task<Void, Never>?
    // A hook-store change arrived while a reload was in flight; reload again after.
    private var changePending = false
    // Holds a pending rate-limited reload when changes arrive faster than the floor.
    private var deferredReloadTask: Task<Void, Never>?

    // The directory watcher is the primary freshness mechanism; pull access only needs an
    // occasional safety refresh.
    private static let cacheTTL: TimeInterval = 60.0
    // Floor between event-driven reloads so a chatty agent cannot thrash the ~1.6s loader.
    private static let minEventReloadInterval: TimeInterval = 2.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private init() {}

    /// Read the cached snapshot for the given (workspaceId, panelId). Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Heavy loader for refresh tasks. Call off-main; menu paths should read the cache.
    nonisolated static func loadIndexForRefresh(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        registry: CmuxVaultAgentRegistry? = nil,
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry]? = nil
    ) -> RestorableAgentSessionIndex {
        let resolvedRegistry = registry ?? CmuxVaultAgentRegistry.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: resolvedRegistry,
            detectedSnapshots: detectedSnapshots ?? RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: resolvedRegistry,
                fileManager: fileManager
            )
        )
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    /// Start the watcher and refresh if the cache has aged past the fallback TTL.
    func scheduleRefreshIfStale() {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        startReload()
    }

    private func startReload() {
        deferredReloadTask?.cancel()
        deferredReloadTask = nil
        refreshTask = Task { @MainActor [weak self] in
            let newIndex = await Task.detached(priority: .utility) {
                // agent-index-load-ok: off-main cache loader.
                Self.loadIndexForRefresh()
            }.value
            guard let self else { return }
            self.applyLoadedIndex(newIndex)
            self.refreshTask = nil
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    /// Coalesce and rate-limit reloads triggered by hook-store directory changes.
    private func handleHookStoreChange() {
        if refreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
        } else if deferredReloadTask == nil {
            // Bounded, cancellable delay to honor the reload floor (not a sync
            // substitute): wait the remainder, then re-evaluate.
            let wait = Self.minEventReloadInterval - elapsed
            deferredReloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.deferredReloadTask = nil
                self.handleHookStoreChange()
            }
        }
    }

    private func ensureWatchingHookStoreDirectory() {
        guard directoryWatchSource == nil else { return }
        let dir = RestorableAgentKind.claude
            .hookStoreFileURL()
            .deletingLastPathComponent()
            .path
        // Create cmux's own hook directory so first-run sessions are watchable immediately.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        // Hook writes are atomic renames, so directory write/link/rename events are enough.
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

    private func applyLoadedIndex(_ newIndex: RestorableAgentSessionIndex?) {
        index = newIndex
        loadedAt = Date()
        indexDidChangeSubject.send()
    }

#if DEBUG
    func replaceIndexForTesting(_ newIndex: RestorableAgentSessionIndex?) {
        applyLoadedIndex(newIndex)
    }

    func resetForTesting() {
        refreshTask?.cancel()
        refreshTask = nil
        deferredReloadTask?.cancel()
        deferredReloadTask = nil
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        changePending = false
        index = nil
        loadedAt = nil
    }
#endif
}
