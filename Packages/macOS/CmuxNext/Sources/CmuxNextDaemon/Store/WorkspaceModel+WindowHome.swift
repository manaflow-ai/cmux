import Foundation

/// Each window's own Home (cmux#27880). The store has one home workspace (`kind` "home",
/// `workspace.ensure_home`), and a workspace lives in one window, so a second window showed the
/// first window's Home (its click brought that window forward). A window that does not hold the
/// store's home gets a Home of its own: a workspace the app makes holding Home's page tab
/// (`home-dock`), the same Chief view, with its own right column. The tree is the truth: a
/// workspace is a window's Home while it holds that page, so it is known as one after a relaunch,
/// on every client, with no record of the app's own.
extension WorkspaceModel {
    /// The page tab of a docked Home (`HomeDock.page`).
    public static let homeDockPage = "home-dock"

    /// A window's own Home: not the store's home workspace, and a pane's first tab is Home's page
    /// (the pinned dock keeps its page first; before the dock it is its pane's only tab). Reads one
    /// tab per pane, so an observer of it does not follow every tab of the workspace.
    public var isWindowHome: Bool {
        kind != "home" && screens.contains { $0.panes.contains { $0.tabs.first?.page == Self.homeDockPage } }
    }

    /// The store's home workspace or a window's own Home.
    public var isAnyHome: Bool { kind == "home" || isWindowHome }
}
