import AppKit
import CmuxNextDaemon
import CmuxNextWakeups

/// Pending window record saves: at most one write in flight and one
/// requested after it, so saves are bounded and land in order.
struct WindowRecordSaves {
    var requested = false
    var scheduled = false
    var inFlight = false
    /// Tickets of the actions whose changes the next write carries; they
    /// close once it lands, so `action.run` answers after the record is
    /// stored (plans/cmux-next/state-ownership.md 3 and 4).
    var tickets: [CommandTicket] = []
    /// The task draining saves, so the quit flush can await it.
    var drain: Task<Void, Never>?
}

/// Writes the window records in the daemon's `personal` projection
/// (state-ownership.md 3): each holds the window's selected tab per pane and
/// its focused pane, and is written on every selection or focus change,
/// coalesced within one main-actor turn. Geometry still settles for 500 ms
/// first, so a window drag does not write per frame. Owned by
/// `WindowManager` (`recordSaver`).
@MainActor
final class WindowRecordSaver {
    unowned let manager: WindowManager
    /// Debounced save of window geometry (architecture.md 1: 500 ms).
    let geometryTimer = DemandTimer(owner: "WindowManager.geometry")
    /// Coalesced saves of the window records.
    var saves = WindowRecordSaves()
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

    /// Records the window's focused pane when it changed (the focus
    /// coordinator settled), and saves.
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
        DaemonCommandScope.$current.withValue(nil) {
            // task-owner: one coalesced save per main-actor turn; drainSaves ends when no save is requested
            saves.drain = Task { @MainActor [weak self] in await self?.drainSaves() }
        }
    }

    /// Writes the records once more through the same queue, after any write
    /// in flight, so an older write cannot land after it (quit).
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
            let failure = await saveNow()
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
            return nil
        } catch {
            services.daemon.logger.error("window state save failed: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    func currentRecords() -> [WindowRecord] {
        let ordered = NSApp.orderedWindows
        let value = manager.registry.value
        let states = manager.states
        return value.windows.compactMap { window in
            let controller = manager.controller(for: window.id)
            let order = controller?.window.flatMap { ordered.firstIndex(of: $0) }
                ?? (value.recency.firstIndex(of: window.id) ?? 0) + ordered.count
            var record = value.record(window.id, state: states[window.id], order: order,
                                      isFullScreen: controller?.window?.styleMask.contains(.fullScreen) ?? false,
                                      selectedTabs: selectedTabs(window: window))
            record?.focusedPane = states[window.id].flatMap { $0.focus.state.pane ?? $0.savedFocusedPane }
            return record
        }
    }

    /// Remembered tab per pane across the window's workspaces.
    private func selectedTabs(window: WindowRegistry.Window) -> [String: String] {
        guard let state = manager.states[window.id] else { return [:] }
        var selected: [String: String] = [:]
        for id in window.workspaceIDs {
            for pane in services.workspace(id: id)?.screens.flatMap(\.panes) ?? [] {
                if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
            }
        }
        return selected
    }
}
