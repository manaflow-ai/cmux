/// What the focus state machine needs to know about the workspace a window
/// shows: panes in layout order, their tabs (strip order) and the selected
/// tab. Built by `WorkspaceContentController` from the daemon mirror and the
/// window's client-local selection (plans/cmux-next/focus.md section 4).
nonisolated struct FocusTopology: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
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

    struct Tab: Hashable, Sendable, Codable {
        var id: String
        /// Daemon surface id; nil for session-local browser tabs.
        var surface: String?
        var kind: Kind

        init(id: String, surface: String? = nil, kind: Kind) {
            self.id = id
            self.surface = surface
            self.kind = kind
        }
    }

    struct Pane: Hashable, Sendable, Codable {
        var id: String
        var tabs: [Tab]
        var selected: String?

        init(id: String, tabs: [Tab], selected: String? = nil) {
            self.id = id
            self.tabs = tabs
            self.selected = selected
        }

        func tab(_ id: String) -> Tab? { tabs.first { $0.id == id } }

        var selectedTab: Tab? { selected.flatMap(tab) }
    }

    /// One column of a screen: its stable id (the layout column id; a split
    /// screen's one column uses the screen id) and its pane ids in layout
    /// order. The id says whether a pane is still in the same column after
    /// a change (close-focus.md), not merely alive.
    struct Column: Hashable, Sendable, Codable {
        var id: String
        var panes: [String]

        init(id: String, panes: [String]) {
            self.id = id
            self.panes = panes
        }
    }

    var workspace: String?
    var panes: [Pane]
    /// Every screen's columns in visual order (left sticky, strip, right
    /// sticky; a split screen is one column). The close-focus rule reads
    /// them (close-focus.md). Empty means one screen with one column
    /// holding `panes` in order.
    var screens: [[Column]]

    init(workspace: String? = nil, panes: [Pane] = [], screens: [[Column]] = []) {
        self.workspace = workspace
        self.panes = panes
        self.screens = screens
    }

    /// The columns of the screen that holds `pane`.
    func columns(containing pane: String) -> [Column]? {
        if screens.isEmpty { return panes.contains { $0.id == pane } ? [Column(id: "", panes: panes.map(\.id))] : nil }
        return screens.first { $0.contains { $0.panes.contains(pane) } }
    }

    /// Column id -> panes, over every screen.
    var columnsByID: [String: [String]] {
        if screens.isEmpty { return ["": panes.map(\.id)] }
        return Dictionary(screens.flatMap { $0 }.map { ($0.id, $0.panes) }, uniquingKeysWith: { first, _ in first })
    }

    func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }

    func contains(pane id: String) -> Bool { panes.contains { $0.id == id } }

    /// Pane and tab holding the tab with this id.
    func location(ofTab id: String) -> (pane: String, tab: String)? {
        for pane in panes where pane.tabs.contains(where: { $0.id == id }) { return (pane.id, id) }
        return nil
    }

    /// Pane and tab showing this daemon surface.
    func location(ofSurface surface: String) -> (pane: String, tab: String)? {
        for pane in panes {
            if let tab = pane.tabs.first(where: { $0.surface == surface }) { return (pane.id, tab.id) }
        }
        return nil
    }

    var allTabIDs: Set<String> { Set(panes.flatMap { $0.tabs.map(\.id) }) }

    /// Selects `tab` in `pane` in this copy (the applier makes it real).
    mutating func select(_ tab: String, in pane: String) {
        guard let index = panes.firstIndex(where: { $0.id == pane }) else { return }
        panes[index].selected = tab
    }
}
