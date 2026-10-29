import AppKit
public import CmuxNextWakeups

// The row views the list builds while the app starts (`SidebarModel.LaunchRows`):
// only the rows the clip shows until startup completes, then the overscan rows in one afterStartup task.
extension SidebarListViewComponents {
    /// Row views made so far against the rows the clip shows now.
    func launchRowsReport() -> SidebarModel.LaunchRows.Report {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let shown = displayed.rowIndices(from: visible.minY, to: visible.maxY).count(where: { index in
            frame(for: displayed.rows[index]).intersects(visible)
        })
        return .init(built: rowPool.made, visible: shown)
    }

    /// Ends the launch's hold: the overscan rows get views now, and the pool parks two realization
    /// rects of them again (`fitToClip`).
    func releaseOffscreenRows() {
        guard launchRows.holdsOffscreenRows else { return }
        launchRows.holdsOffscreenRows = false
        fitToClip()
    }
}

extension SidebarView {
    /// What the list built before startup completed (`SidebarModel.LaunchRows`); nil until then, and for a
    /// window made after launch.
    public var launchRowsReport: SidebarModel.LaunchRows.Report? { list.launchRows.report }

    /// Follows the launch's `startup` while it runs: the list builds views only for the rows
    /// its clip shows; at completion it records what it built (`report` gets it too, for `debug.startup` and
    /// the startup bench), and an afterStartup main task gives the overscan rows their views. Call it right
    /// after making the sidebar, before its first layout. Nothing happens for a nil `startup` (tests) or one
    /// that already completed (a window made after launch).
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - report: Told what the list built before completion, once.
    public func followLaunch(_ startup: StartupScheduler?, report: @escaping @MainActor (SidebarModel.LaunchRows.Report) -> Void) {
        guard let startup, startup.completion == nil else { return }
        list.launchRows.holdsOffscreenRows = true
        startup.whenComplete { [weak list] _ in
            guard let list else { return }
            let rows = list.launchRowsReport()
            list.launchRows.report = rows
            report(rows)
        }
        startup.post(.afterStartup, "Sidebar.offscreenRows", on: .main) { [weak list] in list?.releaseOffscreenRows() }
    }
}
