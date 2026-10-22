#if DEBUG
import AppKit

/// What a workspace row's right-click costs before its menu shows, for `debug.context_menu` and
/// perf-gate.py's `context_menu` scenario (u9786: "right click workspace also feels laggy?").
/// Builds the menu as the right-click does, through the sidebar's menu provider, without showing
/// it. Host-independent: `drawn_rows` (row views made anywhere in the menu) against `shown_rows`
/// (the menu's own rows, the ones that show when it opens). Timing: each build's milliseconds.
struct SidebarMenuOpenProbe {
    /// The sidebar's menu provider (`SidebarListView.contextMenuProvider`).
    let provider: (SidebarContextTarget) -> NSMenu?

    /// Builds the menu of `workspace`'s row `count` times and reports the cost of the builds.
    func measure(workspace: WorkspaceID, count: Int) -> [String: Double] {
        var times: [Double] = []
        var last: NSMenu?
        for _ in 0..<max(1, count) {
            let start = ContinuousClock.now
            last = provider(.workspaces([workspace]))
            times.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        guard let menu = last else { return ["built": 0] }
        times.sort()
        return ["built": 1, "builds": Double(times.count), "p50_ms": times[times.count / 2], "max_ms": times.last ?? 0,
                "first_ms": times.first ?? 0, "drawn_rows": Double(drawn(menu)), "shown_rows": Double(menu.items.filter { $0.view != nil }.count),
                "items": Double(items(menu))]
    }

    private func drawn(_ menu: NSMenu) -> Int {
        menu.items.reduce(0) { $0 + ($1.view == nil ? 0 : 1) + ($1.submenu.map(drawn) ?? 0) }
    }

    private func items(_ menu: NSMenu) -> Int {
        menu.items.reduce(0) { $0 + 1 + ($1.submenu.map(items) ?? 0) }
    }
}

extension SidebarView {
    /// `debug.context_menu`: the cost of `workspace`'s row menu, built `count` times (``SidebarMenuOpenProbe``).
    public func debugMeasureContextMenu(workspace: String, count: Int) -> [String: Double] {
        guard let provider = list.contextMenuProvider else { return ["built": 0] }
        return SidebarMenuOpenProbe(provider: provider).measure(workspace: WorkspaceID(workspace), count: count)
    }
}
#endif
