import AppKit
import CmuxNextActions
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
    /// The daemon window records this install last put, by window id
    /// (`window-records-v1`): written again only when they change.
    private var mirrored: [String: JSONValue] = [:]
    /// Whether this run read the daemon's records of this install once, so
    /// records of windows that are gone (an earlier run) get deleted.
    private var reconciled = false
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
        DaemonCommandScope.$current.withValueInTask(nil) {
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
            await mirror(records)
            return nil
        } catch {
            services.daemon.logger.error("window state save failed: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    /// Mirrors each window into the daemon's window records
    /// (`window-records-v1`, reopen-closed.md 4): which workspaces it lists
    /// and whether it is open. Closed history names the window each group
    /// left from them, and a window that closes becomes a `window` group.
    /// Only those fields go there (a selection change writes nothing); the
    /// window projection above stays the restore record. A failed write is
    /// logged and tried again on the next save.
    private func mirror(_ records: [WindowRecord]) async {
        let daemon = services.daemon
        guard daemon.supports(DaemonCapabilities.shared.windowRecords), let connection = daemon.connection,
              let install = try? services.cloud.localDeviceID() else { return }
        let registry = manager.registry.value
        if !reconciled, let stored = try? await connection.state.windowRecordIDs(installID: install) {
            reconciled = true
            // Known as written, so the loop below deletes the ones no window wants.
            for id in stored where mirrored[id] == nil { mirrored[id] = .null }
        }
        var wanted: [String: JSONValue] = [:]
        for record in records {
            var fields: [String: JSONValue] = ["id": .string(record.id), "open": .bool(registry.window(record.id)?.isOpen ?? true),
                                               "workspace_keys": .array(record.workspaceKeys.map { .string($0.rawValue) })]
            if let key = record.workspaceKey { fields["workspace_key"] = .string(key.rawValue) }
            wanted[record.id] = .object(fields)
        }
        for (id, record) in wanted where mirrored[id] != record {
            do {
                try await connection.state.putWindowRecord(installID: install, windowID: id, record: record)
                mirrored[id] = record
            } catch {
                daemon.logger.error("window_record.put failed: \(String(describing: error), privacy: .public)")
            }
        }
        for id in Set(mirrored.keys).subtracting(wanted.keys) {
            do {
                try await connection.state.deleteWindowRecord(installID: install, windowID: id)
                mirrored[id] = nil
            } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                mirrored[id] = nil
            } catch {
                // Kept: the next save tries the delete again.
                daemon.logger.error("window_record.delete failed: \(String(describing: error), privacy: .public)")
            }
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
                                      isFullScreen: controller?.window?.styleMask.contains(.fullScreen) == true
                                          || states[window.id]?.restoresFullScreen == true,
                                      selectedTabs: selectedTabs(window: window))
            record?.focusedPane = states[window.id].flatMap { $0.focus.state.pane ?? $0.savedFocusedPane }
            record?.focusedPanes = focusedPanes(window: window)
            return record
        }
    }

    /// The pane last focused in each workspace the window lists: the focus
    /// machine's memory, and the shown workspace's current pane.
    private func focusedPanes(window: WindowRegistry.Window) -> [String: String] {
        guard let state = manager.states[window.id] else { return [:] }
        let focus = state.focus.state
        var panes = focus.remembered
        if let workspace = focus.topology.workspace, let pane = focus.pane { panes[workspace] = pane }
        let listed = Set(window.workspaceIDs)
        return panes.filter { listed.contains($0.key) }
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
