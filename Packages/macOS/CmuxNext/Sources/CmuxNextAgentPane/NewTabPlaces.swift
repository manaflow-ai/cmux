public import CmuxNextDaemon

/// The places a New Tab page's bar suggests: the open tabs and other workspaces a jump lands
/// somewhere real on, and the open tabs' folders.
///
/// Pure: it reads only the tab records it is given, so it is tested without the app. Make one per
/// read with this Mac's home folder:
///
/// ```swift
/// let places = NewTabPlaces(home: NSHomeDirectory()).places(sources, current: workspaceID, excluding: pageID)
/// ```
@MainActor
public struct NewTabPlaces {
    /// One workspace as the bar reads it.
    public struct Source {
        /// The workspace's id.
        public var id: String
        /// Its name as the sidebar shows it.
        public var name: String
        /// Its tabs, in order.
        public var tabs: [TabModel]

        /// Creates a source.
        /// - Parameters:
        ///   - id: The workspace's id.
        ///   - name: Its name.
        ///   - tabs: Its tabs, in order.
        public init(id: String, name: String, tabs: [TabModel]) {
            self.id = id
            self.name = name
            self.tabs = tabs
        }

        /// A workspace of the store as the bar reads it: its id, its shown name and the tabs of each pane of each screen.
        /// - Parameter workspace: The store's workspace.
        public init(_ workspace: WorkspaceModel) {
            self.init(id: workspace.id, name: workspace.displayName, tabs: workspace.screens.flatMap(\.panes).flatMap(\.tabs))
        }
    }

    /// What one tab reads as in the bar: its kind, a title of its own and the line under it.
    public typealias Place = (kind: AgentPaneTabKind, title: String, detail: String?)

    /// The bar's open tabs, other workspaces and folders, as one New Tab page lists them.
    public typealias Lists = (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String])

    /// The address of a page with nothing on it, the title a New Tab page starts with.
    public static let blankPage = "about:blank"

    /// This Mac's home folder: `~` in the rows, and never a project.
    public var home: String

    /// Creates the reader.
    /// - Parameter home: This Mac's home folder.
    public init(home: String) { self.home = home }

    /// The open tabs, other workspaces and folders the bar suggests: only places a jump lands
    /// somewhere real on (Leo 2026-10-11: "about:blank Home", a bare "~ ~" folder, each
    /// workspace twice). A New Tab page, a page tab and a blank browser tab are no place; a chat
    /// is one; the home folder is not a project. Another workspace with one place lists once, as
    /// that tab: a row that reads as a tab jumps to the tab (Leo 2026-10-19).
    /// - Parameters:
    ///   - workspaces: Every workspace, in the sidebar's order.
    ///   - current: The workspace the page's window shows; it is not suggested.
    ///   - selectedID: The page's own tab, never suggested.
    ///   - icon: A browser tab's favicon as a `data:` URL.
    /// - Returns: The tab rows, the workspace rows and the folders, each in order.
    public func places(_ workspaces: [Source], current: String?, excluding selectedID: String?,
                       icon: (TabModel) -> String? = { _ in nil })
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        var tabs: [AgentPaneOmnibar.Tab] = []
        var others: [AgentPaneOmnibar.Workspace] = []
        var folders: [String] = []
        for workspace in workspaces {
            for folder in workspace.tabs.compactMap(\.cwd) where folder != home && !folders.contains(folder) { folders.append(folder) }
            let rows = workspace.tabs.filter { $0.id != selectedID }.compactMap { tab in
                place(tab).map { place in
                    AgentPaneOmnibar.Tab(id: tab.id, kind: place.kind, title: place.title, detail: place.detail,
                                         workspace: workspace.name, icon: place.kind == .browser ? icon(tab) : nil)
                }
            }
            tabs += rows
            // Another workspace's only place is that tab's row (Switch to tab lands on it), not the workspace's.
            guard workspace.id != current, rows.count != 1 else { continue }
            let detail = workspace.tabs.lazy.compactMap(\.cwd).first.map(abbreviated)
            others.append(AgentPaneOmnibar.Workspace(id: workspace.id, name: workspace.name, detail: detail))
        }
        return (tabs, others, folders)
    }

    /// One workspace's part of the bar's lists, as values: made when that workspace
    /// changes, and read by each New Tab page after it, so a page's open maps no workspace.
    public nonisolated struct Rows: Equatable, Sendable {
        /// The workspace's id.
        public var id: String
        /// Its name as the sidebar shows it.
        public var name: String
        /// A row for each of its tabs that is a place, in order, with no icon; no tab is left out here.
        public var tabs: [AgentPaneOmnibar.Tab]
        /// The line under the workspace's own row.
        public var detail: String?
        /// Its tabs' folders that are not the home folder, each once, in order.
        public var folders: [String]
        /// The machine that holds the workspace: the icon of a row is looked up there, so a
        /// tab id that 2 machines have gets the icon of its own tab. Nil where the maker names no machine.
        public var machine: String?
    }

    /// `workspace`'s rows: what ``places(_:current:excluding:icon:)`` makes of it before it leaves out the page's
    /// own tab and the shown workspace, with no icon. A kept row has no icon: a map that
    /// reads an icon is mapped again for each icon that arrives, so the icon of a row is read when a page lists it.
    /// - Parameters:
    ///   - workspace: One workspace.
    ///   - machine: The machine that holds it.
    public func rows(_ workspace: Source, machine: String? = nil) -> Rows {
        var folders: [String] = []
        for folder in workspace.tabs.compactMap(\.cwd) where folder != home && !folders.contains(folder) { folders.append(folder) }
        let tabs = workspace.tabs.compactMap { tab in
            place(tab).map { place in
                AgentPaneOmnibar.Tab(id: tab.id, kind: place.kind, title: place.title, detail: place.detail, workspace: workspace.name)
            }
        }
        let detail = workspace.tabs.lazy.compactMap(\.cwd).first.map(abbreviated)
        return Rows(id: workspace.id, name: workspace.name, tabs: tabs, detail: detail, folders: folders, machine: machine)
    }

    /// The bar's tab rows and workspace rows from kept rows: the lists of ``places(_:current:excluding:icon:)``
    /// for the same workspaces, or the first `limit` rows of each, with the icon of each listed browser row from `icon`.
    /// With a limit it stops at the workspace that fills both lists, so its work does not grow with the session where the lists fill.
    /// - Parameters:
    ///   - kept: Every workspace's rows, in the sidebar's order.
    ///   - current: The workspace the page's window shows; it is not suggested.
    ///   - selectedID: The page's own tab, never suggested.
    ///   - limit: The most rows of each list; nil for every row.
    ///   - icon: `(machine, tab id)`: the favicon of that machine's browser tab, as a `data:` URL.
    public static func listed(_ kept: [Rows], current: String?, excluding selectedID: String?, limit: Int? = nil,
                              icon: (String?, String) -> String? = { _, _ in nil })
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace]) {
        var tabs: [AgentPaneOmnibar.Tab] = []
        var others: [AgentPaneOmnibar.Workspace] = []
        let limit = limit ?? Int.max
        for workspace in kept {
            if tabs.count >= limit, others.count >= limit { break }
            let rows = workspace.tabs.filter { $0.id != selectedID }
            for var row in rows.prefix(limit - tabs.count) {
                if row.kind == .browser { row.icon = icon(workspace.machine, row.id) }
                tabs.append(row)
            }
            // Another workspace's only place is that tab's row (Switch to tab lands on it), not the workspace's.
            guard workspace.id != current, rows.count != 1, others.count < limit else { continue }
            others.append(AgentPaneOmnibar.Workspace(id: workspace.id, name: workspace.name, detail: workspace.detail))
        }
        return (tabs, others)
    }

    /// The folders of every kept workspace, each once, in order: the folders of ``places(_:current:excluding:icon:)``.
    /// - Parameter kept: Every workspace's rows, in the sidebar's order.
    public static func folders(_ kept: [Rows]) -> [String] {
        var folders: [String] = []
        var seen: Set<String> = []
        for workspace in kept {
            for folder in workspace.folders where seen.insert(folder).inserted { folders.append(folder) }
        }
        return folders
    }

    /// `tab` as a bar row; nil for no place (a New Tab page, a blank browser, a page tab).
    public func place(_ tab: TabModel) -> Place? {
        let title = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = !title.isEmpty && title != Self.blankPage
        switch tab.kind {
        case .browser:
            // A browser on `about:blank` is no place, whatever its title says ("about:blank Home").
            guard let url = tab.url.flatMap({ $0 == Self.blankPage || $0.isEmpty ? nil : Self.displayURL($0) }) else { return nil }
            let shown = named ? title : url
            return (.browser, shown, url == shown ? nil : url)
        case .pty, .remoteTerminal:
            let folder = tab.cwd.map(abbreviated)
            // A shell titled with its folder alone is named by that folder.
            let shown = named && title != tab.cwd && title != folder ? title : folder ?? (named ? title : nil)
            guard let shown else { return nil }
            return (.terminal, shown, folder == shown ? nil : folder)
        case .conversation:
            // A chat (an agent session) is a place; a New Tab page (no session yet) and a page tab are not.
            guard tab.agentSession?.session != nil, named else { return nil }
            return (.agent, title, tab.cwd.map(abbreviated))
        case .other:
            return nil
        }
    }

    /// `~/code/app` for a folder under ``home``, as the bar shows it.
    public func abbreviated(_ path: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `vite.dev/guide` for `https://vite.dev/guide/`.
    public nonisolated static func displayURL(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
