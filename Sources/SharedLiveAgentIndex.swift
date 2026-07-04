import Combine
import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex: ObservableObject {
    static let shared = SharedLiveAgentIndex()

    @Published private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var processScopeFingerprint: Set<ProcessScopeKey> = []
    private var refreshTask: Task<Void, Never>?
    private var changePending = false
    private var deferredReloadTask: Task<Void, Never>?

    private static let cacheTTL: TimeInterval = 60.0
    private static let minEventReloadInterval: TimeInterval = 2.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let processSnapshotProvider: @MainActor () -> CmuxTopProcessSnapshot
    private let synchronousIndexLoader: @MainActor (CmuxTopProcessSnapshot) -> RestorableAgentSessionIndex
    private let hookStoreDirectoryProvider: @MainActor () -> String

    init(
        processSnapshotProvider: @escaping @MainActor () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        },
        synchronousIndexLoader: @escaping @MainActor (CmuxTopProcessSnapshot) -> RestorableAgentSessionIndex = {
            SharedLiveAgentIndex.loadIndexSynchronously(processSnapshot: $0)
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        }
    ) {
        self.processSnapshotProvider = processSnapshotProvider
        self.synchronousIndexLoader = synchronousIndexLoader
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read a process-sensitive snapshot for the Fork Conversation context menu.
    func snapshotForForkAvailability(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        let processSnapshot = processSnapshotProvider()
        let currentFingerprint = Self.processScopeFingerprint(from: processSnapshot)
        if index == nil || currentFingerprint != processScopeFingerprint {
            reloadSynchronously(processSnapshot: processSnapshot, fingerprint: currentFingerprint)
        }
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

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
            let result = await Task.detached(priority: .utility) {
                let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
                return (
                    index: SharedLiveAgentIndex.loadIndexSynchronously(processSnapshot: processSnapshot),
                    fingerprint: SharedLiveAgentIndex.processScopeFingerprint(from: processSnapshot)
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyReloadedIndex(result.index, fingerprint: result.fingerprint)
            self.refreshTask = nil
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func reloadSynchronously(
        processSnapshot: CmuxTopProcessSnapshot,
        fingerprint: Set<ProcessScopeKey>
    ) {
        refreshTask?.cancel()
        refreshTask = nil
        deferredReloadTask?.cancel()
        deferredReloadTask = nil
        changePending = false
        applyReloadedIndex(
            synchronousIndexLoader(processSnapshot),
            fingerprint: fingerprint
        )
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        fingerprint: Set<ProcessScopeKey>
    ) {
        index = newIndex
        loadedAt = Date()
        processScopeFingerprint = fingerprint
    }

    private func handleHookStoreChange() {
        if refreshTask != nil {
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
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }

    private nonisolated static func loadIndexSynchronously(
        processSnapshot: CmuxTopProcessSnapshot
    ) -> RestorableAgentSessionIndex {
        SharedLiveAgentIndexLoader(
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { processSnapshot.sampledAt.timeIntervalSince1970 }
        )
        .loadSynchronously()
    }

    nonisolated private static func processScopeFingerprint(
        from processSnapshot: CmuxTopProcessSnapshot
    ) -> Set<ProcessScopeKey> {
        Set(processSnapshot.cmuxScopedProcesses().map {
            ProcessScopeKey(
                workspaceId: $0.cmuxWorkspaceID,
                panelId: $0.cmuxSurfaceID,
                pid: $0.pid,
                parentPID: $0.parentPID,
                processGroupID: $0.processGroupID,
                terminalProcessGroupID: $0.terminalProcessGroupID,
                name: $0.name,
                path: $0.path
            )
        })
    }

    private struct ProcessScopeKey: Hashable, Sendable {
        let workspaceId: UUID?
        let panelId: UUID?
        let pid: Int
        let parentPID: Int
        let processGroupID: Int?
        let terminalProcessGroupID: Int?
        let name: String
        let path: String?
    }
}
