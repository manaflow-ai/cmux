import CmuxNextDaemon
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
        }
        // Front window most recent.
        for window in windows.reversed() { activate(window.id) }
    }

    private mutating func appendRestored(_ window: Window) {
        openWindow(id: window.id, workspaceIDs: window.workspaceIDs, frame: window.frame, display: window.display)
    }

    /// The saved record of window `id` (nil for an incognito window), with the window-local fields from
    /// `state` (nil when no state exists yet) and `order` (front = 0).
    /// `selectedTabs` is the remembered tab per pane of its workspaces.
    func record(_ id: String, state: WindowState?, order: Int, isFullScreen: Bool = false,
                selectedTabs: [String: String] = [:]) -> WindowRecord? {
        // Incognito windows are never restored: nothing of them is saved.
        guard let window = window(id), !isIncognito(id) else { return nil }
        let selected = state?.workspaceID.flatMap { window.workspaceIDs.contains($0) ? $0 : nil } ?? window.workspaceIDs.first
        return WindowRecord(
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
                }, uniquingKeysWith: { first, _ in first })
        )
    }
}

extension WindowFrame {
    init(rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
