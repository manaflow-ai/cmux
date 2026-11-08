// Catalog rows for one domain. Titles live in ActionCatalog.xcstrings (en, ja and the app's languages).

/// New ▸ {Terminal, Browser, Agent Chat, New Tab Page} ▸ the ten places Fork To forks to (Leo
/// 2026-11-07: "you can fork to new areas, but you can't just add a new split of an arbitrary
/// thing"). One table makes the 4 × 10 rows: a submenu per kind in the pane's New folder (and the
/// pane's ••• menu), each with Fork To's three sections, and a palette row and `cmux pane new-…`
/// verb per kind and place ("New Browser to the Left"). The app opens kind K at place P through one
/// function (`NewAtPlacement`), whose plan is the layout reducer's `new_placement`.
nonisolated enum NewPlacementActionCatalog: ActionCatalogGroup {
    /// A kind the New menu opens.
    struct Kind: Sendable {
        /// The id segment (`new.<kind>.<place>`), also the plan's `kind`.
        let id: String
        let cliName: String
        let symbol: String
        let keywords: [String]
        let rank: Int
        let startsTerminal: Bool
        let title: @Sendable () -> String
    }

    /// A place, named as the fork destinations are (`AgentForkDestination`'s raw values).
    struct Place: Sendable {
        let id: String
        let cliName: String
        let symbol: String
        let keywords: [String]
        /// Fork To's sections: splits 200s, strip columns and row 300s, tab, workspace, window 400s.
        let rank: Int
        let label: @Sendable () -> String
    }

    static let kinds: [Kind] = [
        Kind(id: "terminal", cliName: "terminal", symbol: "terminal", keywords: ["terminal", "shell"], rank: -190, startsTerminal: true,
             title: { String(localized: "action.new.terminal", defaultValue: "Terminal", bundle: .module) }),
        Kind(id: "browser", cliName: "browser", symbol: "globe", keywords: ["browser", "web"], rank: -180, startsTerminal: false,
             title: { String(localized: "action.new.browser", defaultValue: "Browser", bundle: .module) }),
        Kind(id: "agentChat", cliName: "agent-chat", symbol: "message", keywords: ["agent", "chat"], rank: -170, startsTerminal: false,
             title: { String(localized: "action.new.agentChat", defaultValue: "Agent Chat", bundle: .module) }),
        Kind(id: "newTabPage", cliName: "tab-page", symbol: "square.grid.2x2", keywords: ["new tab page", "page"], rank: -160, startsTerminal: false,
             title: { String(localized: "action.new.newTabPage", defaultValue: "New Tab Page", bundle: .module) }),
    ]

    static let places: [Place] = [
        Place(id: "right", cliName: "to-right", symbol: "rectangle.righthalf.inset.filled", keywords: ["split", "right"], rank: 200,
              label: { String(localized: "menu.new.place.right", defaultValue: "to the Right", bundle: .module) }),
        Place(id: "left", cliName: "to-left", symbol: "rectangle.lefthalf.inset.filled", keywords: ["split", "left"], rank: 201,
              label: { String(localized: "menu.new.place.left", defaultValue: "to the Left", bundle: .module) }),
        Place(id: "up", cliName: "above", symbol: "rectangle.tophalf.inset.filled", keywords: ["split", "above", "up"], rank: 202,
              label: { String(localized: "menu.new.place.up", defaultValue: "Above", bundle: .module) }),
        Place(id: "down", cliName: "below", symbol: "rectangle.bottomhalf.inset.filled", keywords: ["split", "below", "down"], rank: 203,
              label: { String(localized: "menu.new.place.down", defaultValue: "Below", bundle: .module) }),
        Place(id: "columnRight", cliName: "to-new-column-right", symbol: "rectangle.split.3x1", keywords: ["column", "right"], rank: 300,
              label: { String(localized: "menu.new.place.columnRight", defaultValue: "to New Column Right", bundle: .module) }),
        Place(id: "columnLeft", cliName: "to-new-column-left", symbol: "rectangle.leftthird.inset.filled", keywords: ["column", "left"], rank: 301,
              label: { String(localized: "menu.new.place.columnLeft", defaultValue: "to New Column Left", bundle: .module) }),
        Place(id: "row", cliName: "to-new-row", symbol: "rectangle.grid.1x2", keywords: ["row", "below"], rank: 302,
              label: { String(localized: "menu.new.place.row", defaultValue: "to New Row", bundle: .module) }),
        Place(id: "tab", cliName: "to-new-tab", symbol: "plus.square", keywords: ["tab"], rank: 400,
              label: { String(localized: "menu.new.place.tab", defaultValue: "to New Tab", bundle: .module) }),
        Place(id: "workspace", cliName: "to-new-workspace", symbol: "rectangle.stack.badge.plus", keywords: ["workspace"], rank: 401,
              label: { String(localized: "menu.new.place.workspace", defaultValue: "to New Workspace", bundle: .module) }),
        Place(id: "window", cliName: "to-new-window", symbol: "macwindow.badge.plus", keywords: ["window"], rank: 402,
              label: { String(localized: "menu.new.place.window", defaultValue: "to New Window", bundle: .module) }),
    ]

    /// The submenu of `kind` in the pane's New folder.
    static func anchorID(_ kind: Kind) -> ActionID { ActionID(rawValue: "new.\(kind.id)") }

    /// The action that opens `kind` at `place`.
    static func actionID(_ kind: Kind, _ place: Place) -> ActionID { ActionID(rawValue: "new.\(kind.id).\(place.id)") }

    /// The kind and place action `id` opens, by their ids; nil for any other action.
    static func parse(_ id: ActionID) -> (kind: String, place: String)? {
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[0] == "new", kinds.contains(where: { $0.id == parts[1] }),
              places.contains(where: { $0.id == parts[2] }) else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    static func descriptors() -> [ActionDescriptor] {
        kinds.flatMap { kind -> [ActionDescriptor] in
            let anchor = anchorID(kind)
            let submenu = ActionDescriptor(
                id: anchor, title: kind.title(), keywords: ["new"] + kind.keywords, category: .pane, symbol: kind.symbol,
                surfaces: [.contextMenu], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [
                    ActionSurfaceCatalog.p(.pane, .create, kind.rank, .submenu, folder: .new),
                ])
            )
            return [submenu] + places.map { place in
                ActionDescriptor(
                    id: actionID(kind, place), title: title(kind.id, place.id),
                    keywords: ["new", "open"] + kind.keywords + place.keywords, category: .pane, symbol: place.symbol,
                    surfaces: [.palette, .contextMenu], targets: [.pane],
                    cliName: "pane new-\(kind.cliName)-\(place.cliName)", startsTerminal: kind.startsTerminal,
                    surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                        ActionSurfaceCatalog.p(.pane, .create, place.rank, in: anchor, label: place.label()),
                    ])
                )
            }
        }
    }

    /// The palette title of `kind` at `place` ("New Browser to the Left"), one string per row so
    /// every language orders it its own way.
    static func title(_ kind: String, _ place: String) -> String {
        switch (kind, place) {
        case ("terminal", "right"): String(localized: "action.new.terminal.right", defaultValue: "New Terminal to the Right", bundle: .module)
        case ("terminal", "left"): String(localized: "action.new.terminal.left", defaultValue: "New Terminal to the Left", bundle: .module)
        case ("terminal", "up"): String(localized: "action.new.terminal.up", defaultValue: "New Terminal Above", bundle: .module)
        case ("terminal", "down"): String(localized: "action.new.terminal.down", defaultValue: "New Terminal Below", bundle: .module)
        case ("terminal", "columnRight"): String(localized: "action.new.terminal.columnRight", defaultValue: "New Terminal to New Column Right", bundle: .module)
        case ("terminal", "columnLeft"): String(localized: "action.new.terminal.columnLeft", defaultValue: "New Terminal to New Column Left", bundle: .module)
        case ("terminal", "row"): String(localized: "action.new.terminal.row", defaultValue: "New Terminal to New Row", bundle: .module)
        case ("terminal", "tab"): String(localized: "action.new.terminal.tab", defaultValue: "New Terminal to New Tab", bundle: .module)
        case ("terminal", "workspace"): String(localized: "action.new.terminal.workspace", defaultValue: "New Terminal to New Workspace", bundle: .module)
        case ("terminal", "window"): String(localized: "action.new.terminal.window", defaultValue: "New Terminal to New Window", bundle: .module)
        case ("browser", "right"): String(localized: "action.new.browser.right", defaultValue: "New Browser to the Right", bundle: .module)
        case ("browser", "left"): String(localized: "action.new.browser.left", defaultValue: "New Browser to the Left", bundle: .module)
        case ("browser", "up"): String(localized: "action.new.browser.up", defaultValue: "New Browser Above", bundle: .module)
        case ("browser", "down"): String(localized: "action.new.browser.down", defaultValue: "New Browser Below", bundle: .module)
        case ("browser", "columnRight"): String(localized: "action.new.browser.columnRight", defaultValue: "New Browser to New Column Right", bundle: .module)
        case ("browser", "columnLeft"): String(localized: "action.new.browser.columnLeft", defaultValue: "New Browser to New Column Left", bundle: .module)
        case ("browser", "row"): String(localized: "action.new.browser.row", defaultValue: "New Browser to New Row", bundle: .module)
        case ("browser", "tab"): String(localized: "action.new.browser.tab", defaultValue: "New Browser to New Tab", bundle: .module)
        case ("browser", "workspace"): String(localized: "action.new.browser.toWorkspace", defaultValue: "New Browser to New Workspace", bundle: .module)
        case ("browser", "window"): String(localized: "action.new.browser.window", defaultValue: "New Browser to New Window", bundle: .module)
        case ("agentChat", "right"): String(localized: "action.new.agentChat.right", defaultValue: "New Agent Chat to the Right", bundle: .module)
        case ("agentChat", "left"): String(localized: "action.new.agentChat.left", defaultValue: "New Agent Chat to the Left", bundle: .module)
        case ("agentChat", "up"): String(localized: "action.new.agentChat.up", defaultValue: "New Agent Chat Above", bundle: .module)
        case ("agentChat", "down"): String(localized: "action.new.agentChat.down", defaultValue: "New Agent Chat Below", bundle: .module)
        case ("agentChat", "columnRight"): String(localized: "action.new.agentChat.columnRight", defaultValue: "New Agent Chat to New Column Right", bundle: .module)
        case ("agentChat", "columnLeft"): String(localized: "action.new.agentChat.columnLeft", defaultValue: "New Agent Chat to New Column Left", bundle: .module)
        case ("agentChat", "row"): String(localized: "action.new.agentChat.row", defaultValue: "New Agent Chat to New Row", bundle: .module)
        case ("agentChat", "tab"): String(localized: "action.new.agentChat.tab", defaultValue: "New Agent Chat to New Tab", bundle: .module)
        case ("agentChat", "workspace"): String(localized: "action.new.agentChat.workspace", defaultValue: "New Agent Chat to New Workspace", bundle: .module)
        case ("agentChat", "window"): String(localized: "action.new.agentChat.window", defaultValue: "New Agent Chat to New Window", bundle: .module)
        case ("newTabPage", "right"): String(localized: "action.new.newTabPage.right", defaultValue: "New Tab Page to the Right", bundle: .module)
        case ("newTabPage", "left"): String(localized: "action.new.newTabPage.left", defaultValue: "New Tab Page to the Left", bundle: .module)
        case ("newTabPage", "up"): String(localized: "action.new.newTabPage.up", defaultValue: "New Tab Page Above", bundle: .module)
        case ("newTabPage", "down"): String(localized: "action.new.newTabPage.down", defaultValue: "New Tab Page Below", bundle: .module)
        case ("newTabPage", "columnRight"): String(localized: "action.new.newTabPage.columnRight", defaultValue: "New Tab Page to New Column Right", bundle: .module)
        case ("newTabPage", "columnLeft"): String(localized: "action.new.newTabPage.columnLeft", defaultValue: "New Tab Page to New Column Left", bundle: .module)
        case ("newTabPage", "row"): String(localized: "action.new.newTabPage.row", defaultValue: "New Tab Page to New Row", bundle: .module)
        case ("newTabPage", "tab"): String(localized: "action.new.newTabPage.tab", defaultValue: "New Tab Page to New Tab", bundle: .module)
        case ("newTabPage", "workspace"): String(localized: "action.new.newTabPage.workspace", defaultValue: "New Tab Page to New Workspace", bundle: .module)
        case ("newTabPage", "window"): String(localized: "action.new.newTabPage.window", defaultValue: "New Tab Page to New Window", bundle: .module)
        default: "\(kind) \(place)"
        }
    }
}

extension ActionID {
    /// Every New action (`new.<kind>.<place>`), kinds in menu order, each kind's places in Fork To's order.
    public static var newPlacementActions: [ActionID] {
        NewPlacementActionCatalog.kinds.flatMap { kind in NewPlacementActionCatalog.places.map { NewPlacementActionCatalog.actionID(kind, $0) } }
    }

    /// The New folder's submenus, one per kind (`new.<kind>`).
    public static var newPlacementSubmenus: [ActionID] { NewPlacementActionCatalog.kinds.map(NewPlacementActionCatalog.anchorID) }

    /// The kind and place this New action opens (`"browser"`, `"left"`), or nil for another action.
    public var newPlacement: (kind: String, place: String)? { NewPlacementActionCatalog.parse(self) }
}

extension ContextMenuCatalog {
    /// The pane menu's New ▸ kind submenus as one New folder, for another pane menu (the pane's
    /// •••) to show the same rows in the same sections. Nil when the pane menu has none.
    public func newPlacementFolder() -> ContextMenuEntry? {
        let kinds = Set(ActionID.newPlacementSubmenus)
        func found(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
            entries.flatMap { entry -> [ContextMenuEntry] in
                switch entry {
                case .submenu(let id, _) where kinds.contains(id): [entry]
                case .submenu(_, let children), .folder(_, let children), .group(_, let children): found(children)
                case .action, .separator, .choices: []
                }
            }
        }
        let submenus = found(entries(for: .pane))
        return submenus.isEmpty ? nil : .folder(.new, submenus)
    }
}
