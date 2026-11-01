/// One right-click menu as Settings > Menus edits it: its rows (with titles and icons, where the
/// app generates each), the layout drawn now, and whether the person changed it.
public nonisolated struct ContextMenuEditorMenu: Sendable, Hashable {
    public nonisolated struct Row: Sendable, Hashable {
        public enum Kind: String, Sendable { case item, submenu, folder }
        /// ``ContextMenuLayout/key(of:)``.
        public let key: String
        public let title: String
        /// An SF Symbol, or nil for a row without its own icon.
        public let symbol: String?
        public let kind: Kind
        /// The folder key the app generates the row in; nil for the top level.
        public let home: String?
    }

    public let context: ActionMenuContext
    public let title: String
    public let area: ActionMenuContext.MenuArea
    public let rows: [Row]
    /// The generated menu (``ContextMenuLayout/generated(_:)``): what Reset draws.
    public let generated: ContextMenuLayout
    /// The layout drawn now, normalized against the generated menu.
    public let layout: ContextMenuLayout
    public let isCustomized: Bool
}

extension ActionRegistry {
    /// Every menu Settings > Menus offers, in ``ActionMenuContext/editorOrder``: those the app
    /// generates rows for.
    public func contextMenuEditorMenus() -> [ContextMenuEditorMenu] {
        ActionMenuContext.editorOrder.compactMap { context in
            let generated = ContextMenuCatalog.shared.entries(for: context)
            guard !generated.isEmpty else { return nil }
            let labels = ContextMenuCatalog.shared.labels(for: context)
            let rows = ContextMenuLayout.units(in: generated).map { unit in
                editorRow(unit, labels: labels)
            }
            let saved = contextMenuLayouts[context]
            let layout = (saved ?? .generated(generated)).normalized(against: generated)
            return ContextMenuEditorMenu(context: context, title: context.menuName, area: context.menuArea, rows: rows,
                                         generated: .generated(generated), layout: layout,
                                         isCustomized: saved.map { !$0.isGenerated(for: generated) } ?? false)
        }
    }

    private func editorRow(_ unit: ContextMenuLayout.Unit, labels: [ActionID: String]) -> ContextMenuEditorMenu.Row {
        switch unit.entry {
        case .folder(let folder, _):
            return .init(key: unit.key, title: folder.title, symbol: folder.symbol, kind: .folder, home: unit.home)
        case .group(let group, _):
            return .init(key: unit.key, title: group.title, symbol: nil, kind: .folder, home: unit.home)
        case .action(let id), .choices(let id), .submenu(let id, _):
            let symbol = descriptor(for: id)?.symbol
            let kind: ContextMenuEditorMenu.Row.Kind = if case .action = unit.entry { .item } else { .submenu }
            return .init(key: unit.key, title: labels[id] ?? title(for: id) ?? id.rawValue,
                         symbol: symbol == "command" ? nil : symbol, kind: kind, home: unit.home)
        case .separator:
            return .init(key: ContextMenuLayout.separator, title: "", symbol: nil, kind: .item, home: unit.home)
        }
    }
}

extension ActionMenuContext {
    /// Where Settings > Menus lists a menu.
    public enum MenuArea: String, Sendable, CaseIterable {
        case workspace, tabs, terminal, browser, other
    }

    /// The menus in the order Settings > Menus lists them: the ones people open most first.
    public static let editorOrder: [ActionMenuContext] = [
        .workspaceRow, .workspaceGroup, .sidebarBackground, .sidebarItem, .sidebarSection, .sidebarFooter, .profile,
        .priorityRow, .nowPlayingCard, .sshMachine, .cloudMachine, .machineSection, .joinedMachine,
        .tab, .tabGroup, .pane, .newTab, .windowBackground, .screen, .screenGroup, .screenBar,
        .terminalSelection,
        .browserPage, .browserLink, .browserImage, .browserSelection, .browserProfile, .bookmark, .bookmarksBar, .bookmarkManager,
        .agentChat, .fileExplorerRow, .notification,
    ]

    public var menuArea: MenuArea {
        switch self {
        case .workspaceRow, .workspaceGroup, .sidebarBackground, .sidebarItem, .sidebarSection, .sidebarFooter, .profile,
             .priorityRow, .nowPlayingCard, .sshMachine, .cloudMachine, .machineSection, .joinedMachine: .workspace
        case .tab, .tabGroup, .pane, .newTab, .windowBackground, .screen, .screenGroup, .screenBar: .tabs
        case .terminalSelection: .terminal
        case .browserPage, .browserLink, .browserImage, .browserSelection, .browserProfile, .bookmark, .bookmarksBar, .bookmarkManager: .browser
        case .agentChat, .fileExplorerRow, .notification: .other
        }
    }

    /// The menu's name in Settings > Menus: what the person right-clicks.
    public var menuName: String {
        switch self {
        case .tab: String(localized: "menu.name.tab", defaultValue: "Tab", bundle: .module)
        case .tabGroup: String(localized: "menu.name.tabGroup", defaultValue: "Tab Group", bundle: .module)
        case .screen: String(localized: "menu.name.screen", defaultValue: "Screen", bundle: .module)
        case .screenGroup: String(localized: "menu.name.screenGroup", defaultValue: "Screen Group", bundle: .module)
        case .pane: String(localized: "menu.name.pane", defaultValue: "Pane", bundle: .module)
        case .workspaceRow: String(localized: "menu.name.workspaceRow", defaultValue: "Workspace", bundle: .module)
        case .workspaceGroup: String(localized: "menu.name.workspaceGroup", defaultValue: "Workspace Group", bundle: .module)
        case .sidebarBackground: String(localized: "menu.name.sidebarBackground", defaultValue: "Sidebar", bundle: .module)
        case .terminalSelection: String(localized: "menu.name.terminalSelection", defaultValue: "Terminal", bundle: .module)
        case .browserPage: String(localized: "menu.name.browserPage", defaultValue: "Web Page", bundle: .module)
        case .browserLink: String(localized: "menu.name.browserLink", defaultValue: "Link", bundle: .module)
        case .browserImage: String(localized: "menu.name.browserImage", defaultValue: "Image", bundle: .module)
        case .browserSelection: String(localized: "menu.name.browserSelection", defaultValue: "Selected Text", bundle: .module)
        case .cloudMachine: String(localized: "menu.name.cloudMachine", defaultValue: "Cloud Machine", bundle: .module)
        case .sshMachine: String(localized: "menu.name.sshMachine", defaultValue: "SSH Machine", bundle: .module)
        case .machineSection: String(localized: "menu.name.machineSection", defaultValue: "Machine Header", bundle: .module)
        case .newTab: String(localized: "menu.name.newTab", defaultValue: "New Tab Button", bundle: .module)
        case .profile: String(localized: "menu.name.profile", defaultValue: "Room", bundle: .module)
        case .browserProfile: String(localized: "menu.name.browserProfile", defaultValue: "Browser Profile", bundle: .module)
        case .bookmark: String(localized: "menu.name.bookmark", defaultValue: "Bookmark", bundle: .module)
        case .bookmarksBar: String(localized: "menu.name.bookmarksBar", defaultValue: "Bookmarks Bar", bundle: .module)
        case .bookmarkManager: String(localized: "menu.name.bookmarkManager", defaultValue: "Bookmark Manager", bundle: .module)
        case .screenBar: String(localized: "menu.name.screenBar", defaultValue: "Screen Bar", bundle: .module)
        case .notification: String(localized: "menu.name.notification", defaultValue: "Notification", bundle: .module)
        case .sidebarItem: String(localized: "menu.name.sidebarItem", defaultValue: "Sidebar Item", bundle: .module)
        case .sidebarFooter: String(localized: "menu.name.sidebarFooter", defaultValue: "Sidebar Footer", bundle: .module)
        case .sidebarSection: String(localized: "menu.name.sidebarSection", defaultValue: "Sidebar Section", bundle: .module)
        case .agentChat: String(localized: "menu.name.agentChat", defaultValue: "Agent Chat", bundle: .module)
        case .windowBackground: String(localized: "menu.name.windowBackground", defaultValue: "Window Background", bundle: .module)
        case .nowPlayingCard: String(localized: "menu.name.nowPlayingCard", defaultValue: "Now Playing", bundle: .module)
        case .fileExplorerRow: String(localized: "menu.name.fileExplorerRow", defaultValue: "File", bundle: .module)
        case .priorityRow: String(localized: "menu.name.priorityRow", defaultValue: "Priority Chat", bundle: .module)
        case .joinedMachine: String(localized: "menu.name.joinedMachine", defaultValue: "Joined Machine", bundle: .module)
        }
    }
}
