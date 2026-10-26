import AppKit

/// The rows a launch builds before startup completes (p08-startup-064). With 60 workspaces the
/// overscan (`SidebarStyle.overscan`: three subtitle rows' height, 108 to 138 pt) built 3 to 6
/// rows past the screen (`SidebarStartupRowsTests` checks it is more than 2), so a launch holds
/// them until after startup. Chrome builds what the person sees first and posts the rest as
/// after-startup work (chrome/browser/after_startup_task_utils.cc).
struct SidebarStartupRows {
    /// True from the launch hold until `release`: the list realizes the rows on screen only.
    private(set) var isHeld = false
    /// Row views the list had made when the hold ended (nil while it holds, or with no hold).
    private(set) var builtBeforeRelease: Int?
    /// Rows on screen when the hold ended.
    private(set) var visibleAtRelease: Int?

    mutating func hold() {
        guard builtBeforeRelease == nil else { return }
        isHeld = true
    }

    /// Ends the hold, recording what was built under it; false when there was none.
    mutating func release(built: Int, visible: Int) -> Bool {
        guard isHeld else { return false }
        isHeld = false
        builtBeforeRelease = built
        visibleAtRelease = visible
        return true
    }
}

extension SidebarListViewComponents {
    /// A launch: rows past the screen wait for `releaseOffscreenRows`.
    func holdOffscreenRows() {
        startupRows.hold()
    }

    /// After startup: the overscan rows get their views in one realize pass, and the pool its
    /// limit for the wider realization rect.
    func releaseOffscreenRows() {
        guard startupRows.release(built: rowPool.made, visible: rowsOnScreen) else { return }
        fitToClip()
    }

    /// The realized rows whose frame meets the visible clip.
    var rowsOnScreen: Int {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        return rowViews.values.filter { $0.frame.intersects(visible) }.count
    }
}

extension SidebarViewComponents {
    /// Builds only the rows on screen until `releaseOffscreenRows` (a launch, before startup completes).
    public func holdOffscreenRowsForLaunch() {
        list.holdOffscreenRows()
    }

    /// Startup completed: the rows past the screen get their views.
    public func releaseOffscreenRows() {
        list.releaseOffscreenRows()
    }

    /// `debug.sidebar_rows` "startup_rows": whether the launch hold is on, the row views built
    /// before it ended and the rows on screen then (nil until it ends).
    func startupRowsReport() -> [String: Any] {
        let rows = list.startupRows
        return ["held": rows.isHeld,
                "built": rows.builtBeforeRelease.map { $0 as Any } ?? NSNull(),
                "visible": rows.visibleAtRelease.map { $0 as Any } ?? NSNull(),
                "made": list.rowPool.made]
    }
}
