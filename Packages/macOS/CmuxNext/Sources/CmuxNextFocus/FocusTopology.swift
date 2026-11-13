/// What the focus state machine needs to know about the workspace a window
/// shows: panes in layout order, their tabs (strip order) and the selected
/// tab. Built by `WorkspaceContentController` from the daemon mirror and the
/// window's client-local selection (plans/cmux-next/focus.md section 4).
/// The input of `cmux-focus-core`'s `Topology` (same JSON shape); the
/// close-focus and expectation lookups run there.
public nonisolated struct FocusTopology: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal
        case browser
        /// An agent chat tab: the acpmux React pane's web view.
        case agent
        /// An internal page tab (Settings, Debug Settings): a native view.
        case page
        /// A conversation tab (Home): the native transcript; its message box
        /// is the primary input (spec/app-screens.md section 3).
        case conversation
        /// A tab kind the app shows no content for.
        case other
    }

    public struct Tab: Hashable, Sendable, Codable {
        public var id: String
        /// Daemon surface id; nil for session-local browser tabs and for tabs the window minted
        /// (their expectations name the tab id: the surface changes when the daemon confirms them).
        public var surface: String?
        public var kind: Kind

        public init(id: String, surface: String? = nil, kind: Kind) {
            self.id = id
            self.surface = surface
            self.kind = kind
        }
    }

    public struct Pane: Hashable, Sendable, Codable {
        public var id: String
        public var tabs: [Tab]
        public var selected: String?

        public init(id: String, tabs: [Tab], selected: String? = nil) {
            self.id = id
            self.tabs = tabs
            self.selected = selected
        }

        public func tab(_ id: String) -> Tab? { tabs.first { $0.id == id } }

        public var selectedTab: Tab? { selected.flatMap(tab) }
    }

    /// One column of a screen: its stable id (the layout column id; a split
    /// screen's one column uses the screen id) and its pane ids in layout
    /// order. The id says whether a pane is still in the same column after
    /// a change (close-focus.md), not merely alive.
    public struct Column: Hashable, Sendable, Codable {
        public var id: String
        public var panes: [String]

        public init(id: String, panes: [String]) {
            self.id = id
            self.panes = panes
        }
    }

    public var workspace: String?
    public var panes: [Pane]
    /// Every screen's columns in visual order (left docked, strip, right
    /// docked; a split screen is one column). The close-focus rule reads
    /// them (close-focus.md). Empty means one screen with one column
    /// holding `panes` in order.
    public var screens: [[Column]]

    public init(workspace: String? = nil, panes: [Pane] = [], screens: [[Column]] = []) {
        self.workspace = workspace
        self.panes = panes
        self.screens = screens
    }

    public func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }

    public func contains(pane id: String) -> Bool { panes.contains { $0.id == id } }

    /// This topology without `pane`, as the daemon's tree without it will show it: its column keeps
    /// its id and loses the pane, and a column left empty goes (`PaneController.showPaneClose`).
    public func removing(pane id: String) -> FocusTopology {
        var topology = self
        topology.panes.removeAll { $0.id == id }
        topology.screens = screens.map { columns in
            columns.compactMap { column in
                var column = column
                column.panes.removeAll { $0 == id }
                return column.panes.isEmpty ? nil : column
            }
        }
        return topology
    }

    /// Without pane `id`, each of its tabs `carry` gives a pane (moves that empty it) carried there first, as
    /// `carry` returns it (the kind its store reports): a moved tab never leaves the topology, so its browser
    /// focus mode stays. A tab whose destination the topology lacks leaves with the pane.
    public func removing(pane id: String, carrying carry: (Tab) -> (pane: String, tab: Tab)?) -> FocusTopology {
        var topology = self
        for tab in pane(id)?.tabs ?? [] {
            guard let moved = carry(tab), let index = topology.panes.firstIndex(where: { $0.id == moved.pane }),
                  topology.panes[index].tab(moved.tab.id) == nil else { continue }
            topology.panes[index].tabs.append(moved.tab)
        }
        return topology.removing(pane: id)
    }

    public var allTabIDs: Set<String> { Set(panes.flatMap { $0.tabs.map(\.id) }) }
}
