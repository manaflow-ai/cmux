import CmuxNextDaemon
import CmuxNextLayout
import CoreGraphics
import Foundation

// Persistence: the registry is saved in the daemon's `personal` window
// projection (`WindowStateStore`), one `WindowRecord` per window, together
// with that window's own `WindowState` fields.

extension WindowRegistry {
    /// Rebuilds membership from saved records, front window first. A
    /// workspace listed by two records (older builds let every window show
    /// any workspace) stays with the frontmost; records left with nothing
    /// are dropped (a window exists only while it holds a workspace), so an
    /// empty record from an older build or another client never shows.
    init(records: [WindowRecord]) {
        self.init()
        let ordered = records.sorted { $0.order < $1.order }
        var owned = Set<String>()
        for record in ordered {
            var ids = record.workspaceKeys.map(\.rawValue)
            if ids.isEmpty, let shown = record.workspaceKey?.rawValue { ids = [shown] }
            ids = ids.filter { owned.insert($0).inserted }
            guard !ids.isEmpty else { continue }
            appendRestored(Window(id: record.id, workspaceIDs: ids, frame: record.frame?.rect, display: record.display))
            // A window the user closed stays closed, with its workspaces (Cmd-Shift-T reopens it).
            if record.isClosed { setRestored(record.id, open: false) }
        }
        // Front window most recent.
        for window in windows.reversed() { activate(window.id) }
        // With every window closed (the last one closed, then quit), the front one opens, as before.
        if !windows.contains(where: \.isOpen), let front = recency.first { setRestored(front, open: true) }
    }

    private mutating func appendRestored(_ window: Window) {
        openWindow(id: window.id, workspaceIDs: window.workspaceIDs, frame: window.frame, display: window.display)
    }

    /// The saved record of window `id` (nil for an incognito window), with the window-local fields from
    /// `state` (nil when no state exists yet) and `order` (front = 0).
    /// `selectedTabs` is the remembered tab per pane of its workspaces; `machines` the machine each
    /// workspace was last seen on (`WindowManager.seenMachine`), of which the record keeps those
    /// that are not this Mac.
    func record(_ id: String, state: WindowState?, order: Int, isFullScreen: Bool = false,
                selectedTabs: [String: String] = [:], machines: [String: String] = [:]) -> WindowRecord? {
        // Incognito windows are never restored: nothing of them is saved.
        guard let window = window(id), !isIncognito(id) else { return nil }
        let selected = state?.workspaceID.flatMap { window.workspaceIDs.contains($0) ? $0 : nil } ?? window.workspaceIDs.first
        var record = WindowRecord(
            id: id,
            workspaceKey: selected.map(WorkspaceKey.init(rawValue:)),
            workspaceKeys: window.workspaceIDs.map(WorkspaceKey.init(rawValue:)),
            machine: state.flatMap { $0.machineID == MachineRegistry.localID ? nil : $0.machineID },
            screenID: state?.activeScreenID.map(ResourceID.init(rawValue:)),
            frame: window.frame.map(WindowFrame.init(rect:)),
            display: window.display,
            isFullScreen: isFullScreen,
            sidebarWidth: state?.sidebarWidth,
            sidebarHidden: state?.sidebarHidden ?? false,
            selectedTabs: selectedTabs,
            order: order,
            profile: state.flatMap { $0.profileID == .defaultProfile ? nil : $0.profileID },
            profileWorkspaces: Dictionary(
                (state?.profileWorkspaces ?? [:]).compactMap { profile, workspace in
                    window.workspaceIDs.contains(workspace) ? (profile.rawValue, WorkspaceKey(rawValue: workspace)) : nil
                }, uniquingKeysWith: { first, _ in first }),
            page: state?.page?.rawValue,
            isClosed: !window.isOpen
        )
        for workspace in window.workspaceIDs {
            if let machine = machines[workspace], machine != MachineRegistry.localID { record.workspaceMachines[workspace] = machine }
        }
        // The workspaces shown side by side (`sidebar.multiView`), those the window still lists.
        let shown = state?.viewSet?.pruned(keeping: window.workspaceIDs.contains)
        record.multiView = shown.flatMap { $0.ids.count > 1 && $0.contains(selected ?? "") ? $0.record : nil }
        // The docked workspaces (`window.dockedWorkspaces`), those the window still lists.
        if var docks = state?.docks, LayoutTunables.dockedWorkspaces.value {
            docks.prune(keeping: window.workspaceIDs.contains)
            docks.store(into: &record, stage: state?.stageWorkspaceID.flatMap { window.workspaceIDs.contains($0) ? $0 : nil })
        }
        return record
    }
}

extension WindowFrame {
    init(rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: Docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md)

extension WindowDocks {
    /// The docks a saved window had; unknown edges are skipped and extents clamped.
    init(record: WindowRecord) {
        self.init()
        if record.dockOrientation == "rowMajor" { orientation = .rowMajor }
        for saved in record.docks ?? [] {
            guard let edge = DockEdge(rawValue: saved.edge) else { continue }
            dock(saved.workspaceKey.rawValue, at: edge, mode: saved.mode == "floating" ? .overlay : .docked,
                 extentPermille: saved.extentPermille)
            if saved.hidden { _ = toggle(edge) }
        }
    }

    /// Writes the docks, orientation and stage into `record`; no docks write no field.
    func store(into record: inout WindowRecord, stage: String?) {
        guard !all.isEmpty else {
            record.docks = nil
            record.dockOrientation = nil
            record.stageKey = nil
            return
        }
        record.docks = all.map {
            WindowDockRecord(edge: $0.edge.rawValue, workspaceKey: WorkspaceKey(rawValue: $0.workspace),
                             mode: $0.mode == .overlay ? "floating" : "docked", extentPermille: $0.extentPermille, hidden: $0.hidden)
        }
        record.dockOrientation = orientation == .columnMajor ? nil : orientation.rawValue
        record.stageKey = stage.map(WorkspaceKey.init(rawValue:))
    }
}
