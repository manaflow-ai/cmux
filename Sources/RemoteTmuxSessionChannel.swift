import CmuxRemoteSession
import Foundation

/// A per-session view over a shared per-host control stream.
///
/// When one `tmux -CC` connection multiplexes several of a host's sessions (a host
/// that permits only a single concurrent connection), each session gets a
/// `RemoteTmuxSessionChannel` that scopes the shared connection down to that
/// session's windows: topology reads are filtered to the session's window ids,
/// `%output`/events are delivered only for its panes, and sizing goes through
/// per-window `resizeWindow`. A `RemoteTmuxSessionMirror` therefore renders a
/// multiplexed session through the exact same `RemoteTmuxSessionSource` path it uses
/// for a dedicated per-session connection — no mirror-side special-casing.
///
/// The channel is a decorator over `any RemoteTmuxSessionSource`, so it wraps the
/// real control connection in production and a fake in tests.
@MainActor
final class RemoteTmuxSessionChannel: RemoteTmuxSessionSource {
    /// The shared per-host control stream this channel scopes.
    let underlying: any RemoteTmuxSessionSource

    /// The real tmux session id (`$N`) this channel represents, stable across renames
    /// — distinct from the shared connection's own attached (view) session id.
    private(set) var scopedSessionId: Int?
    private var scopedSessionName: String

    /// The tmux window ids that belong to this session, ORDERED by the home
    /// session's window indexes; refreshed by the coordinator as the host's
    /// topology changes (via ``updateWindowIds(_:)``). The order matters: the
    /// shared stream's own `windowOrder` is the hidden VIEW session's link order
    /// (whatever sequence windows happened to be linked in), so deriving tab
    /// order from it would scramble tabs — this stored order is the session's
    /// real one and is what ``windowOrder`` serves to the mirror.
    private(set) var windowIds: [Int]

    /// Set mirror of `windowIds` for the O(1) membership tests on the hot
    /// event-filter and scoped-read paths; kept in lockstep with the array.
    private var windowIdSet: Set<Int>

    /// The panes owned by this session's windows, derived from `windowIds` and the
    /// shared topology. Cached so the hot `%output` path is an O(1) membership test
    /// instead of rescanning every window on every output chunk; rebuilt whenever the
    /// window set or the shared topology changes.
    private var ownedPaneIds: Set<Int> = []

    /// Last topology slice fanned to observers; an event that leaves it unchanged is
    /// another session's churn. Includes every topology-published scoped read consumed
    /// by the mirror, not just window structs, so header/title-row changes notify.
    private struct PaneHeaderSignature: Equatable {
        var paneId: Int
        var label: String
    }

    private struct WindowTitleRowSignature: Equatable {
        var windowId: Int
        var placement: RemoteTmuxPaneTitleRowPlacement
    }

    private struct TopologySignature: Equatable {
        var windows: [RemoteTmuxWindow] = []
        var paneHeaderLabels: [PaneHeaderSignature] = []
        var windowTitleRowPlacements: [WindowTitleRowSignature] = []
    }
    private var lastTopologySignature = TopologySignature()

    /// The concrete shared control stream, used only for home-session reorder
    /// verification. Tests can leave it nil and get optimistic success.
    weak var sharedStream: RemoteTmuxControlConnection?
    /// The host view coordinator that can issue session-scoped kill/reconcile nudges.
    weak var coordinator: RemoteTmuxViewConnection?
    /// Records kill/detach intents in the controller-owned planner store.
    var onEndSessionIntent: ((RemoteTmuxMultiplexReconciler.SessionRef, Bool) -> Void)?

    /// This channel's own observers — a filtered fan-out of the shared stream's events.
    private var observers: [UUID: RemoteTmuxSessionObservers] = [:]
    private var underlyingToken: UUID?

    init(
        underlying: any RemoteTmuxSessionSource,
        sessionName: String,
        sessionId: Int?,
        windowIds: [Int]
    ) {
        self.underlying = underlying
        self.scopedSessionName = sessionName
        self.scopedSessionId = sessionId
        self.windowIds = windowIds
        self.windowIdSet = Set(windowIds)
        recomputeOwnedPanes()
        self.underlyingToken = underlying.addObserver(makeFilteringObservers())
    }

    /// Stops fanning events and drops the shared-stream observer. Call when the
    /// session's mirror goes away so the channel doesn't outlive its use.
    func detach() {
        if let token = underlyingToken {
            underlying.removeObserver(token)
            underlyingToken = nil
        }
        observers.removeAll()
    }

    /// Forwards to the shared stream: for a multiplexed session the thing parked on
    /// authentication is the per-host view connection, not this per-session view of it.
    func resumeAfterInteractiveAuth() { sharedStream?.resumeAfterInteractiveAuth() }

    func releaseMirror() { detach() }

    func endSession(kill: Bool) {
        let ref = RemoteTmuxMultiplexReconciler.SessionRef(name: scopedSessionName, id: scopedSessionId)
        onEndSessionIntent?(ref, kill)
        guard kill else { return }
        coordinator?.killWorkspaceSession(ref)
    }

    /// Refreshes the session's ordered window list (coordinator, on reconcile) and
    /// nudges topology observers so the mirror re-reads the now-scoped state (the
    /// mirror's own reconcile sizes any newly-owned windows). The no-op guard is an
    /// ARRAY compare on purpose: an order-only change (remote `swap-window` /
    /// `move-window`) alters no membership but must still notify, or the mirror
    /// would never reorder its tabs to match.
    func updateWindowIds(_ ids: [Int]) {
        guard ids != windowIds else { return }
        windowIds = ids
        windowIdSet = Set(ids)
        recomputeOwnedPanes()
        // A rescope always notifies — refresh the suppression signature so the
        // fan-out gate can't swallow the very rebuild this rescope requires.
        lastTopologySignature = topologySignature()
        for o in observers.values { o.onTopologyChanged?() }
    }

    /// Records the real session id once the coordinator learns it. A nil snapshot
    /// means "not published yet", not "forget the identity we already learned".
    func setScopedSessionId(_ id: Int?) {
        guard let id else { return }
        scopedSessionId = id
    }

    // MARK: - RemoteTmuxSessionSource: scoped reads

    var connectionState: RemoteTmuxConnectionState { underlying.connectionState }
    var exited: Bool { underlying.exited }

    /// Scoped before forwarding: the ring belongs to the shared stream, so without the session's own
    /// id every session on the host writes indistinguishable pane events into it.
    func record(_ event: String) {
        if let scopedSessionId {
            underlying.record("[$\(scopedSessionId)] \(event)")
        } else {
            underlying.record("[\(scopedSessionName)] \(event)")
        }
    }
    var sessionId: Int? { scopedSessionId }
    // These build from this session's OWN ids (windowIds / ownedPaneIds), not a filter
    // over the full shared map, so each read is O(this session's windows) rather than
    // O(all host windows). That keeps a topology fan-out across N channels O(total
    // windows) instead of O(N × total). Result is identical to filtering the full map.
    var windowsByID: [Int: RemoteTmuxWindow] {
        var result: [Int: RemoteTmuxWindow] = [:]
        for id in windowIds { if let window = underlying.windowsByID[id] { result[id] = window } }
        return result
    }
    // The session's OWN stored order (home-session window-index order from the
    // coordinator), NOT the shared stream's order — that one is the hidden view
    // session's link order and bears no relation to this session's tab order.
    // Filtered to windows the shared topology actually has, so a window the
    // coordinator listed but the stream hasn't materialized yet can't surface.
    var windowOrder: [Int] { windowIds.filter { underlying.windowsByID[$0] != nil } }
    var activePaneByWindow: [Int: Int] {
        var result: [Int: Int] = [:]
        for id in windowIds { if let pane = underlying.activePaneByWindow[id] { result[id] = pane } }
        return result
    }
    var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] {
        var result: [Int: RemoteTmuxPaneForegroundState] = [:]
        for pane in ownedPaneIds { if let state = underlying.paneForegroundStates[pane] { result[pane] = state } }
        return result
    }
    // Retention is deliberately UNSCOPED: a retained pane's window just closed, so
    // its ownership is exactly what's undecidable — over-retaining merely delays a
    // sibling surface's teardown until the next `list-windows` snapshot, whereas
    // under-retaining would tear down a live pane.
    var paneIDsRetainedUntilWindowList: Set<Int> { underlying.paneIDsRetainedUntilWindowList }
    var pendingLayouts: [Int: RemoteTmuxPendingLayout] {
        var result: [Int: RemoteTmuxPendingLayout] = [:]
        for id in windowIds { if let pending = underlying.pendingLayouts[id] { result[id] = pending } }
        return result
    }
    var publishedWindowIdByPane: [Int: Int] {
        // From the cached owned-pane set — O(own panes) like the siblings above,
        // never a scan of the full shared map.
        var result: [Int: Int] = [:]
        for pane in ownedPaneIds {
            if let window = underlying.publishedWindowIdByPane[pane] { result[pane] = window }
        }
        return result
    }
    var paneHeaderLabels: [Int: String] {
        var result: [Int: String] = [:]
        for pane in ownedPaneIds { if let label = underlying.paneHeaderLabels[pane] { result[pane] = label } }
        return result
    }
    var windowTitleRowPlacements: [Int: RemoteTmuxPaneTitleRowPlacement] {
        var result: [Int: RemoteTmuxPaneTitleRowPlacement] = [:]
        for id in windowIds { if let placement = underlying.windowTitleRowPlacements[id] { result[id] = placement } }
        return result
    }
    var lastWindowSizes: [Int: (Int, Int)] {
        var result: [Int: (Int, Int)] = [:]
        for id in windowIds { if let size = underlying.lastWindowSizes[id] { result[id] = size } }
        return result
    }
    func hasPendingLayout(windowId: Int) -> Bool {
        windowIdSet.contains(windowId) && underlying.hasPendingLayout(windowId: windowId)
    }

    // MARK: - RemoteTmuxSessionSource: observers

    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
        let token = UUID()
        self.observers[token] = observers
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    // MARK: - RemoteTmuxSessionSource: commands (server-global @window/%pane ids pass through)

    @discardableResult func send(_ command: String) -> Bool { underlying.send(command) }
    @discardableResult func sendNewWindow(_ command: String, completion: @escaping (Int?) -> Void) -> Bool {
        underlying.sendNewWindow(command, completion: completion)
    }
    @discardableResult func sendWindowReorder(_ commands: [String], verification: ((Bool) -> Void)?) -> Bool {
        guard !commands.isEmpty else {
            verification?(true)
            return true
        }
        for command in commands {
            guard underlying.send(command) else { return false }
        }
        guard let sharedStream else {
            // Unit fakes do not have the concrete shared stream; the optimistic
            // channel order is still the source of truth until the next reconcile.
            verification?(true)
            return true
        }
        let sessionName = scopedSessionName
        Task { @MainActor [weak self, weak sharedStream] in
            guard let self, let sharedStream else {
                verification?(true)
                return
            }
            let target = RemoteTmuxHost.shellSingleQuoted(sessionName)
            let lines = await sharedStream.queryWithTimeout(
                "list-windows -t \(target) -F '#{window_id}'",
                timeout: 3,
                reconnectOnTimeout: false
            )
            guard let reply = lines else {
                verification?(false)
                return
            }
            let actual = reply.compactMap {
                RemoteTmuxControlStreamParser.id(
                    Substring($0.trimmingCharacters(in: .whitespacesAndNewlines)),
                    sigil: "@"
                )
            }
            let actualSet = Set(actual)
            let expected = self.windowIds.filter { actualSet.contains($0) }
            verification?(actual == expected)
        }
        return true
    }
    @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool { underlying.sendKeys(paneId: paneId, data: data) }
    @discardableResult func sendTracked(_ command: String, completion: @escaping (Bool) -> Void) -> Bool {
        underlying.sendTracked(command, completion: completion)
    }
    @discardableResult
    func repaintPaneVisibleScreen(paneId: Int) -> UUID? {
        underlying.repaintPaneVisibleScreen(paneId: paneId)
    }
    @discardableResult
    func seedPane(paneId: Int, clearScrollback: Bool) -> UUID? {
        underlying.seedPane(paneId: paneId, clearScrollback: clearScrollback)
    }
    func unsubscribePanePath(paneId: Int) { underlying.unsubscribePanePath(paneId: paneId) }
    func unsubscribePaneReflow(paneId: Int) { underlying.unsubscribePaneReflow(paneId: paneId) }
    func unsubscribePaneHeader(paneId: Int) { underlying.unsubscribePaneHeader(paneId: paneId) }
    func retainWindowSizeClaims(for liveWindowIDs: Set<Int>) {
        // Scope the GC to this session's windows: the shared stream also holds sibling
        // sessions' claims, and forwarding a session-local live set to the underlying
        // would evict them. Drop only our own windows that are no longer live.
        for id in windowIdSet where !liveWindowIDs.contains(id) {
            underlying.removeWindowSizeClaim(windowId: id)
        }
    }
    func removeWindowSizeClaim(windowId: Int) {
        guard windowIdSet.contains(windowId) else { return }
        underlying.removeWindowSizeClaim(windowId: windowId)
    }
    func setSessionName(_ name: String) { scopedSessionName = name }
    /// Applies a reorder of *this session's* windows to the stored home-session order.
    /// The shared stream's own ledger is deliberately untouched: it tracks the hidden
    /// view session's link order, not this session's real tmux window indexes.
    func applyWindowReorder(_ reordered: [Int]) {
        let owned = reordered.filter { windowIdSet.contains($0) }
        let mentioned = Set(owned)
        windowIds = owned + windowIds.filter { !mentioned.contains($0) }
        lastTopologySignature = topologySignature()
    }
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        underlying.queryWindowActivity(windowId: windowId, completion: completion)
    }
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        underlying.queryPaneActivity(paneId: paneId, completion: completion)
    }
    @discardableResult func pastePane(paneId: Int, text: String) -> Bool { underlying.pastePane(paneId: paneId, text: text) }

    // MARK: - RemoteTmuxSessionSource: sizing (per-window, in band)

    func setWindowSize(windowId: Int, columns: Int, rows: Int) {
        guard windowIdSet.contains(windowId) else { return }
        underlying.setWindowSize(windowId: windowId, columns: columns, rows: rows)
    }

    // MARK: - Filtering fan-out

    /// Whether `paneId` belongs to one of this session's windows (output/cwd/reflow
    /// are keyed by server-global pane id). O(1) against the cached owned-pane set.
    private func ownsPane(_ paneId: Int) -> Bool { ownedPaneIds.contains(paneId) }

    /// Rebuilds `ownedPaneIds` from the current window set and shared topology.
    /// Iterates this session's OWN windows (O(this session's windows)) rather than
    /// scanning + layout-walking every host window, so a topology fan-out across N
    /// channels stays O(total windows) instead of O(N × total).
    private func recomputeOwnedPanes() {
        var panes: Set<Int> = []
        for windowId in windowIds {
            guard let window = underlying.windowsByID[windowId] else { continue }
            for pane in window.paneIDsInOrder { panes.insert(pane) }
        }
        ownedPaneIds = panes
    }

    private func topologySignature() -> TopologySignature {
        TopologySignature(
            windows: windowIds.compactMap { underlying.windowsByID[$0] },
            paneHeaderLabels: ownedPaneIds.sorted().compactMap { pane in
                underlying.paneHeaderLabels[pane].map { PaneHeaderSignature(paneId: pane, label: $0) }
            },
            windowTitleRowPlacements: windowIds.compactMap { id in
                underlying.windowTitleRowPlacements[id].map { WindowTitleRowSignature(windowId: id, placement: $0) }
            }
        )
    }

    private func makeFilteringObservers() -> RemoteTmuxSessionObservers {
        RemoteTmuxSessionObservers(
            onPaneOutput: { [weak self] paneId, data in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneOutput?(paneId, data) }
            },
            // Scoped by pane like `%output`: a seed carries the pane's authoritative snapshot, so
            // delivering another session's seed would repaint this session's surface from the wrong pane.
            onPaneSeed: { [weak self] paneId, seed in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneSeed?(paneId, seed) }
            },
            onPaneCwd: { [weak self] paneId, path in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneCwd?(paneId, path) }
            },
            onPaneReflow: { [weak self] paneId, noReflow in
                guard let self, self.ownsPane(paneId) else { return }
                for o in self.observers.values { o.onPaneReflow?(paneId, noReflow) }
            },
            onActivePaneChanged: { [weak self] windowId, paneId in
                guard let self, self.windowIdSet.contains(windowId) else { return }
                for o in self.observers.values { o.onActivePaneChanged?(windowId, paneId) }
            },
            onSessionChanged: { _, _ in
                // The shared stream's %session-changed describes the hidden view session,
                // not this real session; per-session rename is driven by the coordinator.
            },
            // `onAuthRequired` is deliberately NOT fanned. The host's login offer is made once by the
            // view coordinator, which registers it on the shared stream itself
            // (``RemoteTmuxViewConnection/onAuthRequired``); fanning per channel would offer one login
            // tab per session on the host for a single parked stream.
            onTopologyChanged: { [weak self] in
                guard let self else { return }
                self.recomputeOwnedPanes()
                // One shared-stream topology event fans to EVERY channel; a
                // session whose own slice didn't change (another session's
                // resize/layout churn) must not rebuild its mirror. The
                // signature covers everything the rebuild consumes that
                // publishes via topology: order, window values, pane headers,
                // and title-row visibility.
                let signature = self.topologySignature()
                if signature == self.lastTopologySignature { return }
                self.lastTopologySignature = signature
                for o in self.observers.values { o.onTopologyChanged?() }
            },
            // A reconnect re-attaches the shared stream, and every session's mirror has to re-apply
            // its size afterwards: the mirror answers this by force-resizing its visible windows.
            // Host-global by nature, so it fans to every channel.
            onReconnectReady: { [weak self] in
                guard let self else { return }
                for o in self.observers.values { o.onReconnectReady?() }
            },
            onExit: {
                // Deliberately NOT fanned. The shared stream's `%exit` is host-stream
                // death; the view coordinator owns teardown for every session on the
                // host (it removes each mirror + channel and discards the window). Fanning
                // per-channel too would double-tear-down — each mirror would also run the
                // dedicated-connection end path (a one-shot kill a single-connection host
                // refuses, plus a per-session unbind), racing the coordinator. Transient
                // reconnects still reach the mirror via `onConnectionStateChanged` below.
            },
            onConnectionStateChanged: { [weak self] state in
                guard let self else { return }
                for o in self.observers.values { o.onConnectionStateChanged?(state) }
            }
        )
    }
}
