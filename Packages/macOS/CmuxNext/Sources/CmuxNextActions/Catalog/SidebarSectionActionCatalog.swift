// Sidebar sections (plans/cmux-next/sidebar-sections.md 6): add and remove
// items (Home first), add, rename, move, restyle and remove sections, and
// reset the layout. Titles live in SidebarSectionActions.xcstrings. Each
// declares its surfaces inline; the CLI verbs are `cmux sidebar <verb>`.

nonisolated enum SidebarSectionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        items() + sections()
    }

    private static func items() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "sidebar.home.add", title: t("action.sidebar.home.add", "Add Home to Sidebar"),
                keywords: ["home", "sidebar", "section", "pin", "show"], category: .sidebar, symbol: "house",
                surfaces: [.palette, .keyboard, .contextMenu], cliName: "sidebar add-home",
                surfacePlan: plan(menus: [p(.sidebarBackground, .create, 300, folder: .new)])
            ),
            ActionDescriptor(
                id: "sidebar.home.remove", title: t("action.sidebar.home.remove", "Remove Home from Sidebar"),
                keywords: ["home", "sidebar", "section", "unpin", "hide"], category: .sidebar, symbol: "house.slash",
                surfaces: [.palette, .keyboard], cliName: "sidebar remove-home",
                // The Home row's own menu offers Remove from Sidebar.
                surfacePlan: plan(exemption: .familyMember)
            ),
            ActionDescriptor(
                id: "sidebar.item.add", title: t("action.sidebar.item.add", "Add to Sidebar…"),
                keywords: ["sidebar", "section", "pin", "settings", "account", "history", "bookmarks", "notifications"],
                category: .sidebar, symbol: "plus.rectangle.on.rectangle", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [builtInArgument, sectionArgument], cliName: "sidebar add-item",
                surfacePlan: plan(menus: [p(.sidebarBackground, .create, 310, folder: .new), p(.sidebarSection, .create, 110)])
            ),
            ActionDescriptor(
                id: "sidebar.item.removeEverywhere", title: t("action.sidebar.item.removeEverywhere", "Remove from Sidebar"),
                keywords: ["sidebar", "unpin", "remove", "hide", "home"], category: .sidebar, symbol: "minus.circle",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem], cliName: "sidebar remove-from-sidebar",
                surfacePlan: plan(menus: [p(.sidebarItem, .close, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.item.remove", title: t("action.sidebar.item.removeFromSection", "Remove from Section"),
                keywords: ["sidebar", "section", "unpin", "remove"], category: .sidebar, symbol: "minus.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem], cliName: "sidebar remove-item",
                surfacePlan: plan(menus: [p(.sidebarItem, .close, 110)])
            ),
            ActionDescriptor(
                id: "sidebar.item.hideApp", title: t("action.sidebar.item.hideApp", "Hide"),
                keywords: ["sidebar", "app", "hide", "extension"], category: .sidebar, symbol: "eye.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem, .sidebarSection], cliName: "sidebar hide-app",
                // Offered on app items and app sections only (SidebarBridge
                // filters the menus); the app comes from the target.
                surfacePlan: plan(menus: [p(.sidebarItem, .close, 120), p(.sidebarSection, .close, 120)])
            ),
            ActionDescriptor(
                id: "sidebar.item.toggleLabel", title: t("action.sidebar.item.toggleLabel", "Show or Hide Label"),
                keywords: ["sidebar", "item", "label", "icon", "title"], category: .sidebar, symbol: "textformat",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem], cliName: "sidebar toggle-item-label",
                surfacePlan: plan(menus: [p(.sidebarItem, .identity, 100)])
            ),
        ]
    }

    private static func sections() -> [ActionDescriptor] {
        let section: [ActionTargetKind] = [.sidebarSection]
        return [
            ActionDescriptor(
                id: "sidebar.section.add", title: t("action.sidebar.section.add", "New Section…"),
                keywords: ["sidebar", "section", "new", "add", "shelf"], category: .sidebar, symbol: "rectangle.stack.badge.plus",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [titleArgument(required: false), regionArgument],
                cliName: "sidebar add-section",
                surfacePlan: plan(menus: [p(.sidebarBackground, .create, 320, folder: .new), p(.sidebarSection, .create, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.section.rename", title: t("action.sidebar.section.rename", "Rename Section…"),
                keywords: ["sidebar", "section", "rename", "title"], category: .sidebar, symbol: "pencil",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [titleArgument(required: true).renamingTarget], targets: section,
                cliName: "sidebar rename-section", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.section.moveToTop", title: t("action.sidebar.section.moveToTop", "Move Section to Top"),
                keywords: ["sidebar", "section", "move", "top", "pinned"], category: .sidebar, symbol: "arrow.up.to.line",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar move-section-top",
                surfacePlan: plan(menus: [p(.sidebarSection, .move, 100, folder: .move)])
            ),
            ActionDescriptor(
                id: "sidebar.section.moveToScrolling", title: t("action.sidebar.section.moveToScrolling", "Move Section to Scrolling Area"),
                keywords: ["sidebar", "section", "move", "middle", "scroll"], category: .sidebar, symbol: "arrow.up.and.down",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar move-section-scrolling",
                surfacePlan: plan(menus: [p(.sidebarSection, .move, 110, folder: .move)])
            ),
            ActionDescriptor(
                id: "sidebar.section.moveToBottom", title: t("action.sidebar.section.moveToBottom", "Move Section to Bottom"),
                keywords: ["sidebar", "section", "move", "bottom", "pinned"], category: .sidebar, symbol: "arrow.down.to.line",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar move-section-bottom",
                surfacePlan: plan(menus: [p(.sidebarSection, .move, 120, folder: .move)])
            ),
            ActionDescriptor(
                id: "sidebar.section.useBuiltInLook", title: t("action.sidebar.section.useBuiltInLook", "Built-in Look"),
                keywords: ["sidebar", "section", "look", "style", "chrome", "built-in"], category: .sidebar, symbol: "house",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar section-look-built-in",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 200, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.useListLook", title: t("action.sidebar.section.useListLook", "List Look"),
                keywords: ["sidebar", "section", "look", "style", "list", "rows"], category: .sidebar, symbol: "list.bullet",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar section-look-list",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 210, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.layoutList", title: t("action.sidebar.section.layoutList", "Show as List"),
                keywords: ["sidebar", "section", "layout", "list", "rows"], category: .sidebar, symbol: "list.bullet",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar section-layout-list",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 230, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.layoutInline", title: t("action.sidebar.section.layoutInline", "Show on One Line"),
                keywords: ["sidebar", "section", "layout", "inline", "line", "row", "icons", "flex"], category: .sidebar,
                symbol: "rectangle.split.3x1", surfaces: [.palette, .keyboard, .contextMenu], targets: section,
                cliName: "sidebar section-layout-inline", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 240, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.layoutGrid", title: t("action.sidebar.section.layoutGrid", "Show as Grid"),
                keywords: ["sidebar", "section", "layout", "grid", "tiles", "favorites"], category: .sidebar, symbol: "square.grid.2x2",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar section-layout-grid",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 250, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.setAlignment", title: t("action.sidebar.section.setAlignment", "Set Section Alignment…"),
                keywords: ["sidebar", "section", "align", "center", "spread", "flex"], category: .sidebar, symbol: "align.horizontal.center",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [alignArgument], targets: section,
                cliName: "sidebar set-section-alignment", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 260, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.setGap", title: t("action.sidebar.section.setGap", "Set Section Spacing…"),
                keywords: ["sidebar", "section", "gap", "spacing", "flex"], category: .sidebar, symbol: "arrow.left.and.right",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [gapArgument], targets: section,
                cliName: "sidebar set-section-gap", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 270, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.setColumns", title: t("action.sidebar.section.setColumns", "Set Grid Columns…"),
                keywords: ["sidebar", "section", "grid", "columns", "tiles"], category: .sidebar, symbol: "square.grid.3x2",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [columnsArgument], targets: section,
                cliName: "sidebar set-section-columns", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 280, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.toggleTitle", title: t("action.sidebar.section.toggleTitle", "Show or Hide Section Title"),
                keywords: ["sidebar", "section", "title", "label", "header", "hide", "show"], category: .sidebar, symbol: "textformat",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar toggle-section-title",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 220, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.toggleSpaceScope", title: t("action.sidebar.section.toggleSpaceScope", "Show Only in This Space"),
                keywords: ["sidebar", "section", "room", "scope", "all rooms"], category: .sidebar, symbol: "circle.grid.2x2",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar toggle-section-space",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 300, folder: .options)])
            ),
            ActionDescriptor(
                id: "sidebar.section.setMaxRows", title: t("action.sidebar.section.setMaxRows", "Set Section Height…"),
                keywords: ["sidebar", "section", "height", "rows", "scroll", "max"], category: .sidebar, symbol: "arrow.up.and.down.square",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [rowsArgument], targets: section,
                cliName: "sidebar set-section-height", surfacePlan: plan(menus: [p(.sidebarSection, .identity, 310, folder: .options)])
            ),
            ActionDescriptor(
                id: "sidebar.section.toggleCollapsed", title: t("action.sidebar.section.toggleCollapsed", "Collapse or Expand Section"),
                keywords: ["sidebar", "section", "collapse", "expand", "fold"], category: .sidebar, symbol: "chevron.down",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section,
                // Collapse is per-window view state; scripts reach it by id.
                surfacePlan: plan(cli: .exempt(.focusMove), menus: [p(.sidebarSection, .organize, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.section.remove", title: t("action.sidebar.section.remove", "Remove Section"),
                keywords: ["sidebar", "section", "remove", "delete"], category: .sidebar, symbol: "trash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar remove-section",
                destructive: true, surfacePlan: plan(menus: [p(.sidebarSection, .close, 100)])
            ),
            // Leo (2026-10-06): Projects and Chats hide from their headers'
            // menus and come back from the sidebar's menu or Settings
            // (`sidebar.showProjects`, `sidebar.showChats`; scripts set those).
            ActionDescriptor(
                id: "sidebar.section.hide", title: t("action.sidebar.section.hide", "Hide Section"),
                keywords: ["sidebar", "section", "hide", "recents"], category: .sidebar, symbol: "eye.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section,
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarSection, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.projects.hide", title: t("action.sidebar.projects.hide", "Hide Projects"),
                keywords: ["sidebar", "section", "hide", "projects", "workspaces"], category: .sidebar, symbol: "eye.slash",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.sections.showHidden", title: t("action.sidebar.sections.showHidden", "Show Hidden Sections"),
                keywords: ["sidebar", "section", "show", "unhide", "projects", "recents"], category: .sidebar, symbol: "eye",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 110)])
            ),
            // Leo (2026-10-09): the sidebar's and a workspace row's menus
            // check Show Tabs Under Workspaces (`sidebar.showWorkspaceTabs`;
            // scripts set that).
            ActionDescriptor(
                id: "sidebar.workspaceTabs.toggle", title: t("action.sidebar.workspaceTabs.toggle", "Show Tabs Under Workspaces"),
                keywords: ["sidebar", "tabs", "workspace", "show", "list", "nested", "children"], category: .sidebar, symbol: "list.bullet.indent",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 120), p(.workspaceRow, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.layout.reset", title: t("action.sidebar.layout.reset", "Reset Sidebar Layout"),
                keywords: ["sidebar", "section", "reset", "default", "layout"], category: .sidebar, symbol: "arrow.counterclockwise",
                surfaces: [.palette, .keyboard, .contextMenu], cliName: "sidebar reset", destructive: true,
                surfacePlan: plan(menus: [p(.sidebarBackground, .reset, 100, folder: .options)])
            ),
        ]
    }

    // MARK: Arguments

    private static var builtInArgument: ActionArgument {
        let cases: [(String, String)] = [
            ("home", t("argument.sidebar.builtin.home", "Home")),
            ("settings", t("argument.sidebar.builtin.settings", "Settings")),
            ("account", t("argument.sidebar.builtin.account", "Account")),
            ("notifications", t("argument.sidebar.builtin.notifications", "Notifications")),
            ("history", t("argument.sidebar.builtin.history", "History")),
            ("bookmarks", t("argument.sidebar.builtin.bookmarks", "Bookmarks")),
            ("app_store", t("argument.sidebar.builtin.appStore", "App Store")),
            ("new_terminal", t("argument.sidebar.builtin.newTerminal", "New Terminal Tab")),
            ("new_browser", t("argument.sidebar.builtin.newBrowser", "New Browser Tab")),
            ("new_agent_chat", t("argument.sidebar.builtin.newAgentChat", "New Agent Chat")),
            ("search_chats", t("argument.sidebar.builtin.searchChats", "Search Chats")),
            ("customize", t("argument.sidebar.builtin.customize", "Customize Appearance")),
        ]
        // Free text with the built-ins offered: `workspace:<id>` and
        // `app:<publisher>/<name>` put any workspace or app in the top rows
        // (PINNED-ITEMS-END-TO-END P1).
        return ActionArgument(name: "item", title: t("argument.sidebar.item", "Item"), kind: .string,
                              suggestions: ActionSuggestions(source: ActionSuggestions.sidebarItems,
                                                             pinned: cases.map { ActionEnumCase(value: $0.0, title: $0.1) }))
    }

    private static var sectionArgument: ActionArgument {
        ActionArgument(name: "section", title: t("argument.sidebar.section", "Section"), kind: .string, isRequired: false)
    }

    private static func titleArgument(required: Bool) -> ActionArgument {
        ActionArgument(name: "title", title: t("argument.sidebar.title", "Title"), kind: .string, isRequired: required)
    }

    private static var regionArgument: ActionArgument {
        let cases = [
            ActionEnumCase(value: "top", title: t("argument.sidebar.region.top", "Top")),
            ActionEnumCase(value: "middle", title: t("argument.sidebar.region.middle", "Scrolling")),
            ActionEnumCase(value: "bottom", title: t("argument.sidebar.region.bottom", "Bottom")),
        ]
        return ActionArgument(name: "region", title: t("argument.sidebar.region", "Place"), kind: .enumeration(cases), isRequired: false)
    }

    private static var alignArgument: ActionArgument {
        let cases = [
            ActionEnumCase(value: "leading", title: t("argument.sidebar.align.leading", "Leading")),
            ActionEnumCase(value: "center", title: t("argument.sidebar.align.center", "Center")),
            ActionEnumCase(value: "trailing", title: t("argument.sidebar.align.trailing", "Trailing")),
            ActionEnumCase(value: "fill", title: t("argument.sidebar.align.fill", "Spread Out")),
        ]
        return ActionArgument(name: "align", title: t("argument.sidebar.align", "Alignment"), kind: .enumeration(cases))
    }

    private static var gapArgument: ActionArgument {
        ActionArgument(name: "gap", title: t("argument.sidebar.gap", "Spacing (points)"), kind: .int(0...32))
    }

    private static var columnsArgument: ActionArgument {
        ActionArgument(name: "columns", title: t("argument.sidebar.columns", "Columns (0 = as many as fit)"), kind: .int(0...12))
    }

    private static var rowsArgument: ActionArgument {
        ActionArgument(name: "rows", title: t("argument.sidebar.rows", "Rows (0 = automatic)"), kind: .int(0...50))
    }

    // MARK: Helpers

    private static func p(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int, folder: MenuFolder? = nil) -> ContextMenuPlacement {
        ContextMenuPlacement(context, group, rank, folder: folder)
    }

    private static func plan(cli: SurfaceDecision = .offered, menus: [ContextMenuPlacement] = [],
                             exemption: SurfaceExemption? = nil) -> ActionSurfacePlan {
        ActionSurfacePlan(cli: cli, contextMenus: menus, contextMenuExemption: menus.isEmpty ? exemption : nil)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "SidebarSectionActions", bundle: .module)
    }
}
