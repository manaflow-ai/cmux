/// What the focus state machine needs to know about the workspace a window
/// shows: panes in layout order, their tabs (strip order) and the selected
/// tab. Built by `WorkspaceContentController` from the daemon mirror and the
/// window's client-local selection (plans/cmux-next/focus.md section 4).
nonisolated struct FocusTopology: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case terminal
        case browser
        /// A tab kind the app shows no content for.
        case other
    }

    struct Tab: Hashable, Sendable {
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

    struct Pane: Hashable, Sendable {
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

    var workspace: String?
    var panes: [Pane]

    init(workspace: String? = nil, panes: [Pane] = []) {
        self.workspace = workspace
        self.panes = panes
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
