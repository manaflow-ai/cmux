public import CmuxNextDaemon
public import CmuxNextLayout
public import CoreGraphics

// Persistence: the registry is saved in the daemon's `personal` window
// projection (`WindowStateStore`), one `WindowRecord` per window, together
// with that window's own `WindowState` fields (the App's `WindowRegistry+Records`).

@MainActor extension WindowRegistry {
    /// Rebuilds membership from saved records, front window first. A
    /// workspace listed by two records (older builds let every window show
    /// any workspace) stays with the frontmost; records left with nothing
    /// are dropped (a window exists only while it holds a workspace), so an
    /// empty record from an older build or another client never shows.
    public init(records: [WindowRecord]) {
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
        // Front window most recent. With every window closed, none opens (#31514: `WindowManager.restore`).
        for window in windows.reversed() { activate(window.id) }
    }

    private mutating func appendRestored(_ window: Window) {
        openWindow(id: window.id, workspaceIDs: window.workspaceIDs, frame: window.frame, display: window.display)
    }
}

extension WindowFrame {
    public init(rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
