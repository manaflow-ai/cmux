import Darwin
import Foundation
import Observation

/// Process-wide, event-driven cache of `RestorableAgentSessionIndex.load()` results, used
/// by the right-click "Fork Conversation" availability check and the close-history undo
/// snapshot. `load()` runs `sysctl(KERN_PROCARGS2)` per hook record plus disk reads
/// (350ms-1.8s on large agent histories), far too expensive to do synchronously on the
/// main actor, so reloads run on a `Task.detached(priority: .utility)` and callers read
/// the cached snapshot synchronously.
///
/// Freshness is driven by a watcher on the hook-store directory (`~/.cmuxterm`), which the
/// `cmux hooks` CLI writes when an agent session starts or updates. The cache reloads
/// shortly after an actual change (coalesced + rate-limited) and otherwise idles, with a
/// long fallback TTL for pull access. This replaced a 1s pull TTL that reloaded
/// near-continuously while the sidebar was visible, because each load outlasts a 1s TTL.
///
/// `@Observable` lets each workspace track `index` / `processDetectedIndex` via
/// `withObservationTracking` so a reload re-renders ContentView and bonsplit's TabBarView
/// picks up the new snapshot.
@MainActor
@Observable
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var refreshTask: Task<Void, Never>?
    // A hook-store change arrived while a reload was in flight; reload again after.
    private var changePending = false
    // Holds a pending rate-limited reload when changes arrive faster than the floor.
    private var deferredReloadTask: Task<Void, Never>?

    // Process-detection layer. Heavier than the hook-store reload above (a full
    // process snapshot + per-agent transcript/rollout scans), so it is NOT wired
    // into the chatty hook-store watcher. It is loaded lazily on demand and on a
    // slower TTL, and only powers the tab-menu fork fallback for live agents cmux
    // never recorded a hook for (e.g. `sr claude` / direct `codex`, which bypass
    // the cmux wrapper's SessionStart hook).
    private(set) var processDetectedIndex: RestorableAgentSessionIndex?
    private var processDetectedLoadedAt: Date?
    private var processDetectedRefreshTask: Task<Void, Never>?
    private static let processDetectedCacheTTL: TimeInterval = 30.0

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

    /// Current cached index. Never blocks. Used by the close-history undo snapshot so
    /// closing a tab does not pay the synchronous `RestorableAgentSessionIndex.load()`
    /// cost on the main thread. The directory watcher keeps this current; stale tolerance
    /// is fine because restore/resume re-reads transcripts from disk and only uses the
    /// cached snapshot's session identity, not the live PID set.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    /// Process-detected snapshot for a panel (lazy, slower-cadence). Never blocks.
    /// The tab-menu fork affordance reads this as a fallback when neither the
    /// restored snapshot nor the hook-store index resolves the panel, so the
    /// expensive process scan is paid only on demand. When the scan lands, the
    /// Observation-tracked change re-renders subscribed workspaces and the menu item
    /// appears without a second right-click.
    func processDetectedSnapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleProcessDetectedRefreshIfStale()
        return processDetectedIndex?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    private func scheduleProcessDetectedRefreshIfStale() {
        guard processDetectedRefreshTask == nil else { return }
        if let processDetectedLoadedAt,
           Date().timeIntervalSince(processDetectedLoadedAt) < Self.processDetectedCacheTTL {
            return
        }
        processDetectedRefreshTask = Task { @MainActor [weak self] in
            // `loadIncludingProcessDetectedSnapshots` runs the heavy capture +
            // scan off the main actor internally; here we only await + assign.
            let newIndex = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard let self else { return }
            self.processDetectedIndex = newIndex
            self.processDetectedLoadedAt = Date()
            self.processDetectedRefreshTask = nil
        }
    }

    /// Ensure the hook-store watcher is running and refresh if the cache has aged past the
    /// long fallback TTL. The watcher, not this TTL, is the primary freshness path.
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
                // agent-index-load-ok: off-main cache loader (this IS the sanctioned home
                // for load(); everything else should read SharedLiveAgentIndex.shared).
                RestorableAgentSessionIndex.load()
            }.value
            guard let self else { return }
            // Assigning the Observation-tracked `index` invalidates workspaces that
            // read it via `withObservationTracking`, so SwiftUI re-renders.
            self.index = newIndex
            self.loadedAt = Date()
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
        // Ensure the hook-store directory exists so the watcher installs at launch and
        // observes the very first hook write. On a fresh/cleaned install it would
        // otherwise not exist yet, the watcher would not install, and the first agent's
        // session could stay invisible behind the fallback TTL. This is cmux's own state
        // directory (the `cmux hooks` CLI writes here too), so creating it empty is benign.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            // Directory still unavailable (e.g. permissions); retried on the next
            // scheduleRefreshIfStale() (sidebar render / close).
            return
        }
        // A directory-level kqueue source reports entry changes (create/delete/rename) but
        // not in-place data writes to an existing child file. That is sufficient here
        // because every hook-store write is atomic (write-temp + rename, e.g.
        // ClaudeHookSessionStore.saveUnlocked uses `.write(options: .atomic)`), so each
        // update lands as a rename into this directory and fires the source. This matches
        // cmux's existing CmuxConfig watcher, which relies on the same atomic-write
        // invariant. The 60s fallback TTL backstops anything a future non-atomic writer
        // to ~/.cmuxterm might add.
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
        // The watcher may have just been installed after `~/.cmuxterm` first appeared
        // (first run / cleaned state); any hook writes before this moment were unobserved
        // and an earlier empty load may have stamped a "fresh" loadedAt that would
        // suppress the fallback-TTL reload. Force a catch-up reload now.
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }
}
