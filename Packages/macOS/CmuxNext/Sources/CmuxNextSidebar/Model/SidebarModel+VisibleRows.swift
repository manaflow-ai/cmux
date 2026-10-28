import Foundation

extension SidebarModel {
    /// The selectable workspace rows the sidebar draws, in drawn order: the
    /// sidebar's own row layout, so collapsed sections, collapsed groups and
    /// rows the filter hides get no number.
    public var visibleWorkspaceIDs: [String] {
        var options = SidebarLayoutOptions()
        options.filterMatches = filterMatches
        options.sessionTree = SidebarSessionTree.shared.drawn?.shape
        let selectable = Set(selectableWorkspaces.map(\.id))
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key, selectable.contains(id) { id.rawValue } else { nil }
        }
    }

    /// The row views the sidebar builds while the app starts. Chrome builds what a
    /// restored window shows first and leaves the rest to after startup (session restore loads the visible
    /// tab at once and the others later, chrome/browser/sessions/tab_loader.cc;
    /// `AfterStartupTaskUtils::PostTask`, chrome/browser/after_startup_task_utils.cc). The list's overscan
    /// rows (`SidebarStyle.overscan` past each edge) are rows nobody sees yet, so while startup runs the
    /// list builds views only for the rows its clip shows, and the overscan rows come in one afterStartup task.
    public struct LaunchRows: Sendable, Equatable {
        /// What one sidebar built before startup completed, against the rows its clip showed then.
        public struct Report: Sendable, Equatable {
            /// The off-screen rows a launch may build beyond the visible ones (a row cut by each edge).
            public static let slack = 2
            /// Row views the list made (not taken back from its pool), from its creation to completion.
            public let built: Int
            /// Rows the list's clip showed at completion.
            public let visible: Int

            public init(built: Int, visible: Int) {
                self.built = built
                self.visible = visible
            }

            /// The launch built no more than the visible rows and ``slack``.
            public var isWithinVisibleRows: Bool { built <= visible + Self.slack }
        }

        /// True from `SidebarView.followLaunch` until the afterStartup task releases the overscan rows: the
        /// list realizes only the rows its clip shows. False for a window made after startup completed.
        public internal(set) var holdsOffscreenRows = false
        /// What the list built before startup completed; nil until then, and for a window made after launch.
        public internal(set) var report: Report?

        public init() {}
    }
}
