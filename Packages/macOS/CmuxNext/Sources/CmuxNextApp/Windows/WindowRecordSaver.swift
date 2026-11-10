import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextWakeups

/// Pending window record saves: at most one in flight and one after it, in order.
struct WindowRecordSaves {
    var requested = false
    var scheduled = false
    var inFlight = false
    /// Tickets of the actions the next write carries; they close once it lands, so `action.run`
    /// answers after the record is stored (plans/cmux-next/state-ownership.md 3 and 4).
    var tickets: [CommandTicket] = []
    /// The task draining saves, so the quit flush can await it.
    var drain: Task<Void, Never>?
}

/// Writes the window records in the daemon's `personal` projection (state-ownership.md 3): tab per
/// pane and focused pane, on each selection or focus change, coalesced per turn (`WindowRecordSaves`);
/// an unchanged document writes nothing. Geometry settles for 500 ms first. Owned by `WindowManager`.
@MainActor
final class WindowRecordSaver {
    unowned let manager: WindowManager
    /// Debounced save of window geometry (architecture.md 1: 500 ms).
    let geometryTimer = DemandTimer(owner: "WindowManager.geometry")
    /// The focused pane's save waits for the commit that shows the move (``focusDidSettle(_:pane:)``).
    private var afterCommit: CommitProbe?
    /// A focused-pane save waits for that commit, or for ``afterCommitDeadline``.
    private var awaitingCommit = false
    /// Tickets of the focus moves that wait for that commit: they join the save that follows it
    /// (not a write already in flight, which does not carry their pane).
    private var focusTickets: [CommandTicket] = []
    /// The deadline of a focused-pane save whose window shows no commit (occluded, unlit).
    private let afterCommitTimer = DemandTimer(owner: "WindowRecordSaver.afterCommit")
    static let afterCommitDeadline: Duration = .milliseconds(100)
    /// Coalesced saves of the window records.
    var saves = WindowRecordSaves()
    /// The daemon's window records of this install (`window-records-v1`).
    private let recordMirror = WindowRecordMirror()
    /// The remembered tab per pane of each window, as its last record build left them (``selectedTabs(window:in:)``).
    private var selectedTabsCache: [String: SelectedTabs] = [:]
    /// Panes whose remembered tab a record build read on the main thread, since launch. A save reads the panes
    /// that changed, never the session's (`SpaceSwitchRecordSaveTests`).
    private(set) var paneReads = 0
    private var services: AppServices { manager.services }

    init(manager: WindowManager) {
        self.manager = manager
    }

    /// A selection, focus, membership or sidebar change: save on the next turn.
    func stateDidChange(_ state: WindowState) {
        guard manager.restored, !manager.isTerminating else { return }
        requestSave()
    }

    /// A frame change: save once it has settled for 500 ms.
    func geometryDidChange(_ state: WindowState) {
        guard manager.restored, !manager.isTerminating else { return }
        geometryTimer.schedule(after: .milliseconds(500)) { @MainActor [weak self] in self?.requestSave() }
    }

    func scheduleSave() {
        guard let any = manager.states.values.first else { return }
        stateDidChange(any)
    }

    /// Records the window's focused pane when it changed (the focus coordinator settled), and saves.
    func focusDidSettle(_ state: WindowState, pane: String?) {
        guard state.savedFocusedPane != pane else { return }
        state.savedFocusedPane = pane
        guard manager.restored, !manager.isTerminating else { return }
        // The move's frame first (speed-of-sound-DESIGN.md 3.2): the save builds every window's
        // records on the main actor, so it starts once the commit that shows the move ran. The
        // ticket opens now, so the action that moved focus still answers once the record is stored.
        guard let host = manager.controller(for: state.id)?.window?.contentView?.layer else { return requestSave() }
        if let ticket = services.daemon.openTicket() { focusTickets.append(ticket) }
        guard !awaitingCommit else { return }
        awaitingCommit = true
        let probe = afterCommit ?? CommitProbe { [weak self] _, _ in self?.commitShowedFocus() }
        afterCommit = probe
        probe.mark(in: host)
        // Bounded, cancellable deadline (DemandTimer): a window that commits nothing still saves.
        afterCommitTimer.schedule(after: Self.afterCommitDeadline) { @MainActor [weak self] in self?.commitShowedFocus() }
    }

    /// The commit that shows a focus move ran (or its deadline passed): the save it waited for starts.
    private func commitShowedFocus() {
        guard awaitingCommit else { return }
        awaitingCommit = false
        afterCommitTimer.cancel()
        afterCommit?.remove()
        saves.requested = true
        saves.tickets += focusTickets
        focusTickets = []
        scheduleDrain()
    }

    private func requestSave() {
        saves.requested = true
        if let ticket = services.daemon.openTicket() { saves.tickets.append(ticket) }
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard saves.requested, !saves.inFlight, !saves.scheduled else { return }
        saves.scheduled = true
        // Not part of any action's scope: a projection write keeps a fresh
        // mutation id (its CAS retries must not replay an earlier write).
        DaemonCommandScope.$current.withValueInTask(nil) {
            // task-owner: one coalesced save per main-actor turn; drainSaves ends when no save is requested
            saves.drain = Task { @MainActor [weak self] in await self?.drainSaves() }
        }
    }

    /// Writes the records once more after any write in flight, so an older one cannot land after it (quit).
    func flushSaves() async {
        commitShowedFocus()
        requestSave()
        await saves.drain?.value
    }

    private func drainSaves() async {
        saves.scheduled = false
        guard !saves.inFlight else { return }
        saves.inFlight = true
        // wakeup-allow: each iteration writes one requested save; ends when none is pending
        while saves.requested, !manager.isTerminating {
            saves.requested = false
            let tickets = saves.tickets
            saves.tickets = []
            let requested = CACurrentMediaTime()
            let failure = await saveNow()
            if failure == nil { DebugTabSwitch.confirmed(requestedAt: requested) }
            for ticket in tickets { await services.daemon.closeTicket(ticket, label: "save window records", error: failure) }
        }
        saves.inFlight = false
        let leftover = saves.tickets
        saves.tickets = []
        for ticket in leftover { await services.daemon.closeTicket(ticket, label: "save window records", error: nil) }
    }

    /// Writes the records; returns why they were not stored, or nil. Nothing is written while the
    /// stored records are unread (`WindowManager.savedWindowsUnread`): they would be replaced by this
    /// launch's windows alone, and the next launch would lose the others (#26681). That skip answers
    /// nil: the action that asked for the save did its work, only its record is not kept.
    @discardableResult
    func saveNow() async -> (any Error)? {
        guard !manager.savedWindowsUnread else { return nil }
        guard let windowState = services.daemon.windowState else { return DaemonError.notConnected }
        DebugPaneFocus.noteMainWork("record_saves")
        manager.captureGeometry()
        let records = currentRecords()
        // The front open window's place, kept once its record is pruned (`WindowStateDocument.lastFrame`).
        let front = records.filter { !$0.isClosed && $0.frame != nil }.min { $0.order < $1.order }
        // Keys on every machine, plus those whose machine has not loaded yet
        // (they must survive until it reconnects).
        let live = Set(services.machines.allWorkspaces.compactMap(\.0.key))
            .union(records.flatMap(\.workspaceKeys).filter { !manager.isDead($0.rawValue) })
        do {
            try await windowState.update { document in
                document.windows = records
                document.prune(liveWorkspaces: live)
                if let front {
                    document.lastFrame = front.frame
                    document.lastDisplay = front.display
                }
            }
            await mirror(records)
            return nil
        } catch {
            services.daemon.logger.error("window state save failed: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    /// Mirrors the windows into the daemon's window records (`WindowRecordMirror`).
    private func mirror(_ records: [WindowRecord]) async {
        let daemon = services.daemon
        guard daemon.supports(DaemonCapability.windowRecords.rawValue), let connection = daemon.connection,
              let install = try? await services.cloud.installID() else { return }
        await recordMirror.sync(records, installID: install, client: connection.state) { message in
            daemon.logger.error("\(message, privacy: .public)")
        }
    }

    /// Front first by the registry's recency (`WindowManager.windowDidOrder`): a save never asks the
    /// window server (`NSApp.orderedWindows` is a synchronous query, cx-8w027.25).
    func currentRecords() -> [WindowRecord] {
        let value = manager.registry.value
        let states = manager.states
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return value.windows.compactMap { window in
            let controller = manager.controller(for: window.id)
            var record = value.record(window.id, state: states[window.id], order: order[window.id] ?? order.count,
                                      isFullScreen: (controller?.window?.styleMask.contains(.fullScreen) == true
                                          // full screen only for a page's fullscreen is not the window's own
                                          && controller?.pagePresentation?.entersWindowFullScreen != true)
                                          || states[window.id]?.restoresFullScreen == true,
                                      selectedTabs: selectedTabs(window: window, in: value), machines: manager.seenMachine)
            record?.focusedPane = states[window.id].flatMap { $0.focus.state.pane ?? $0.savedFocusedPane }
            record?.focusedPanes = focusedPanes(window: window)
            return record
        }
    }

    /// The pane last focused in each workspace the window lists (focus memory, the shown one's pane).
    private func focusedPanes(window: WindowRegistry.Window) -> [String: String] {
        guard let state = manager.states[window.id] else { return [:] }
        let focus = state.focus.state
        var panes = state.focus.rememberedPanes()
        if let workspace = focus.topology.workspace, let pane = focus.pane { panes[workspace] = pane }
        let listed = Set(window.workspaceIDs)
        return panes.filter { listed.contains($0.key) }
    }

    /// Remembered tab per pane across the window's workspaces, kept between saves. A save applies the selections
    /// that changed since the last one (`TabSelectionMemory.takeChanges`) and reads no pane: nothing after a
    /// workspace or space switch, one entry after a tab switch. Every pane is read again only when the panes
    /// themselves may differ: the window lists other workspaces, or a machine's tree gained, lost or moved a pane or
    /// a tab (`DaemonStore.tabListRevision`). A daemon batch that changes neither (an agent's output, a title, a
    /// status) reads nothing: such batches land between any two actions of a live session, and each one made the
    /// next save read every pane of the window on the main thread, before the frame of the action that asked for it.
    private func selectedTabs(window: WindowRegistry.Window, in registry: WindowRegistry) -> [String: String] {
        guard let memory = manager.states[window.id]?.selection else {
            selectedTabsCache[window.id] = nil
            return [:]
        }
        let tabLists = services.machines.daemons.map { TabListStamp(store: $0.store, revision: $0.store.tabListRevision) }
        // Taken on every path: the full read below reads the memory itself, which has these changes.
        let changes = memory.takeChanges()
        if var cached = selectedTabsCache[window.id], cached.memory === memory, cached.workspaces == window.workspaceIDs,
           cached.tabLists.elementsEqual(tabLists, by: { $0.isSame(as: $1) }) {
            guard !changes.isEmpty else { return cached.tabs }
            for (pane, tab) in changes { cached.tabs[pane] = lists(pane, window: window, in: registry) ? tab : nil }
            selectedTabsCache[window.id] = cached
            return cached.tabs
        }
        var selected: [String: String] = [:]
        for id in window.workspaceIDs {
            for pane in services.workspace(id: id)?.screens.flatMap(\.panes) ?? [] {
                paneReads += 1
                if let tab = memory.selection(in: pane.id) { selected[pane.id] = tab }
            }
        }
        selectedTabsCache[window.id] = SelectedTabs(memory: memory, workspaces: window.workspaceIDs, tabLists: tabLists, tabs: selected)
        return selected
    }

    /// Whether a workspace `window` lists holds a pane with id `pane`, as the full read of
    /// ``selectedTabs(window:in:)`` finds one (a pane of `services.workspace(id:)`), from the stores' indexes and the
    /// registry's owner map: no walk of the window's panes. Its workspaces are searched only for a workspace
    /// another window owns too (the registry names the first window that lists one).
    private func lists(_ pane: String, window: WindowRegistry.Window, in registry: WindowRegistry) -> Bool {
        services.machines.daemons.contains { daemon in
            guard let model = daemon.store.pane(idOrResource: pane), model.id == pane,
                  let workspace = daemon.store.location(of: model)?.workspace,
                  let owner = registry.owner(of: workspace.id) else { return false }
            return (owner == window.id || window.workspaceIDs.contains(workspace.id)) && services.workspace(id: workspace.id) === workspace
        }
    }
}

/// The remembered tabs of one window's panes, and what they were read from besides the selections themselves.
private struct SelectedTabs {
    /// The window's tab memory: a window opened again has another. Weak, so a freed one is never taken for a new one.
    weak var memory: TabSelectionMemory?
    var workspaces: [String]
    var tabLists: [TabListStamp]
    var tabs: [String: String]
}

/// One machine's store and its tab list revision.
private struct TabListStamp {
    /// Weak, so a freed store is never taken for a new one.
    weak var store: DaemonStore?
    var revision: UInt64

    /// Whether `other` is the same live store at the same revision.
    func isSame(as other: TabListStamp) -> Bool {
        store != nil && store === other.store && revision == other.revision
    }
}
