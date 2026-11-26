import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextLayout
import CoreGraphics
import Foundation

// Persistence: the registry is saved in the daemon's `personal` window
// projection (`WindowStateStore`), one `WindowRecord` per window, together
// with that window's own `WindowState` fields. Rebuilding it from them: CmuxNextAppCore's `WindowRegistry+SavedRecords`.

extension WindowRegistry {
    /// The saved record of window `id` (nil for an incognito window), with the window-local fields from
    /// `state` (nil when no state exists yet) and `order` (front = 0).
    /// `selectedTabs` is the remembered tab per pane of its workspaces; `machines` the machine each
    /// workspace was last seen on (`WindowManager.seenMachine`), of which the record keeps those
    /// that are not this Mac.
    func record(_ id: String, state: WindowState?, order: Int, isFullScreen: Bool = false,
                selectedTabs: [String: String] = [:], machines: [String: String] = [:], membership: WindowListMembership<WorkspaceKey>? = nil) -> WindowRecord? {
        // Incognito windows are never restored: nothing of them is saved.
        // A window that owns nothing is only a view of other windows' workspaces (`openView`): they are saved with their
        // owners, and a record that named one would take it from its owner at the next launch (`init(records:)`).
        guard let window = window(id), !isIncognito(id) else { return nil }
        let members = membership ?? WindowListMembership(window: window, machines: machines, localID: MachineRegistry.localID, key: WorkspaceKey.init(rawValue:))
        let lists = members.listed.contains
        guard !members.ownedKeys.isEmpty else { return nil }
        let selected = state?.workspaceID.flatMap { lists($0) ? $0 : nil } ?? window.workspaceIDs.first
        var record = WindowRecord(
            id: id,
            workspaceKey: selected.map(WorkspaceKey.init(rawValue:)),
            workspaceKeys: members.ownedKeys, // a guest is its owner's to save
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
                    lists(workspace) ? (profile.rawValue, WorkspaceKey(rawValue: workspace)) : nil
                }, uniquingKeysWith: { first, _ in first }),
            page: state?.page?.rawValue,
            isClosed: !window.isOpen
        )
        record.workspaceMachines = members.workspaceMachines
        // The workspaces shown side by side (`sidebar.multiView`), those the window still lists.
        let shown = state?.viewSet?.pruned(keeping: lists)
        record.multiView = shown.flatMap { $0.ids.count > 1 && $0.contains(selected ?? "") ? $0.record : nil }
        record.chiefPanel = state?.chiefPanel.record
        // The docked workspaces (`window.dockedWorkspaces`), those the window still lists.
        if var docks = state?.docks, LayoutTunables.dockedWorkspaces.value {
            docks.prune(keeping: lists)
            docks.store(into: &record, stage: state?.stageWorkspaceID.flatMap { lists($0) ? $0 : nil })
        }
        return record
    }
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
            if saved.hidesTabBar { setHidesTabBar(true, of: saved.workspaceKey.rawValue) }
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
                             mode: $0.mode == .overlay ? "floating" : "docked", extentPermille: $0.extentPermille, hidden: $0.hidden,
                             hidesTabBar: $0.hidesTabBar)
        }
        record.dockOrientation = orientation == .columnMajor ? nil : orientation.rawValue
        record.stageKey = stage.map(WorkspaceKey.init(rawValue:))
    }
}
