import AppKit
import CmuxNextActions
import CmuxNextDaemon
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
    /// Coalesced saves of the window records.
    var saves = WindowRecordSaves()
    /// The daemon's window records of this install (`window-records-v1`).
    private let recordMirror = WindowRecordMirror()
    private var selectedTabsCache: [String: (key: SelectedTabsKey, tabs: [String: String])] = [:]
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
        stateDidChange(state)
    }

    private func requestSave() {
        saves.requested = true
        if let ticket = services.daemon.openTicket() { saves.tickets.append(ticket) }
        guard !saves.inFlight, !saves.scheduled else { return }
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

    /// Writes the records; returns why they were not stored, or nil.
    @discardableResult
    func saveNow() async -> (any Error)? {
        guard let windowState = services.daemon.windowState else { return DaemonError.notConnected }
        manager.captureGeometry()
        let records = currentRecords()
        // Keys on every machine, plus those whose machine has not loaded yet
        // (they must survive until it reconnects).
        let live = Set(services.machines.allWorkspaces.compactMap(\.0.key))
            .union(records.flatMap(\.workspaceKeys).filter { !manager.isDead($0.rawValue) })
        do {
            try await windowState.update { document in
                document.windows = records
                document.prune(liveWorkspaces: live)
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
        guard daemon.supports(DaemonCapabilities.shared.windowRecords), let connection = daemon.connection,
              let install = try? services.cloud.localDeviceID() else { return }
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
                                      isFullScreen: controller?.window?.styleMask.contains(.fullScreen) == true
                                          || states[window.id]?.restoresFullScreen == true,
                                      selectedTabs: selectedTabs(window: window))
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

    /// Remembered tab per pane across the window's workspaces, read again only when an input moved
    /// (its tab memory, its workspaces, a daemon batch): a save after a switch reads no pane.
    private func selectedTabs(window: WindowRegistry.Window) -> [String: String] {
        guard let state = manager.states[window.id] else { return [:] }
        let key = SelectedTabsKey(selection: state.selection.revision, workspaces: window.workspaceIDs,
                                  batches: services.machines.daemons.map(\.store.appliedSequence))
        if let cached = selectedTabsCache[window.id], cached.key == key { return cached.tabs }
        var selected: [String: String] = [:]
        for id in window.workspaceIDs {
            for pane in services.workspace(id: id)?.screens.flatMap(\.panes) ?? [] {
                if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
            }
        }
        selectedTabsCache[window.id] = (key, selected)
        return selected
    }
}

private struct SelectedTabsKey: Equatable { var selection: UInt64, workspaces: [String], batches: [UInt64] }
