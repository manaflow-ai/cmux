extension WindowPictureMeta {
    /// What a window's content area shows in its picture at quit: a top page or the empty state, which AppKit draws
    /// with no pane, or the workspace whose content is mounted, with its panes and screens.
    public enum ContentArea: Sendable, Equatable {
        /// A top page, by its persisted route (`TopPageRoute.rawValue`).
        case page(String)
        case workspace(String)
        case empty

        /// The content area of a window showing `page` over `workspaceID`; nil while it shows none of these (a
        /// workspace still mounting, a Cloud workspace being created), so the window leaves no picture.
        ///
        /// - Parameters:
        ///   - page: The top page's persisted route; nil shows the workspace.
        ///   - contentShown: The window's workspace content is mounted and not parked.
        public init?(page: String?, workspaceID: String?, cloudCreating: Bool, contentShown: Bool) {
            if let page {
                self = .page(page)
            } else if cloudCreating {
                return nil
            } else if let workspaceID {
                guard contentShown else { return nil }
                self = .workspace(workspaceID)
            } else {
                self = .empty
            }
        }

        /// The content area of a window a launch opens from its saved state (`WindowState.page`, `.workspaceID`): the
        /// page over the workspace, else the workspace, else the empty state. Its ``layout(workspaces:screens:)`` is the
        /// one the quit wrote for the same window (``init(page:workspaceID:cloudCreating:contentShown:)``), so only a
        /// real change refuses a region.
        public init(page: String?, workspaceID: String?) {
            self = page.map { .page($0) } ?? workspaceID.map { .workspace($0) } ?? .empty
        }

        /// The picture's layout: the window's `workspaces` in sidebar order, what this area shows, and `screens` only
        /// while it shows a workspace (a page or the empty state has no pane tree).
        public func layout(workspaces: [String], screens: [Screen]) -> Layout {
            switch self {
            case .page(let route): Layout(workspaces: workspaces, shown: "top:\(route)", screens: [])
            case .workspace(let id): Layout(workspaces: workspaces, shown: id, screens: screens)
            case .empty: Layout(workspaces: workspaces, shown: nil, screens: [])
            }
        }
    }
}
