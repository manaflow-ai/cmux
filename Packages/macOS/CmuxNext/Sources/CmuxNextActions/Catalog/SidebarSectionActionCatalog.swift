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
            // The Chief item's subagent rows (`ChiefSidebar`): folded, only the working, waiting, failed
            // or lost ones show; checked, the idle ones too. Only the Chief item's right-click menu shows it.
            ActionDescriptor(
                id: "sidebar.chief.toggleIdleSubagents",
                title: t("action.sidebar.chief.toggleIdleSubagents", "Show Idle Chief Subagents"),
                keywords: ["chief", "subagents", "agents", "sidebar", "idle", "show", "hide", "fold", "collapse", "expand"],
                category: .sidebar, symbol: "list.bullet.indent", surfaces: [.palette, .keyboard, .contextMenu],
                // A fold of this Mac's own sidebar view, nothing to script.
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarItem, .view, 50)])
            ),
            // Opens a Chief subagent (target: its row's sidebar item) as its row does; the Chief pane's Subagents menu runs it.
            ActionDescriptor(id: "chief.openSubagent", title: t("action.chief.openSubagent", "Open Chief Subagent"),
                             keywords: ["chief", "subagent", "agent", "open", "show", "chat"], category: .agents, symbol: "person.2",
                             surfaces: [.keyboard], targets: [.sidebarItem],
                             surfacePlan: plan(cli: .exempt(.focusMove), exemption: .focusMove, palette: .exempt(.focusMove))),
            // Pins or unpins a session tree history chat (target: sidebar-item:<chat key>), as its row's
            // right-click menu does (`SidebarChatHistory`); the row retitles it Pin or Unpin.
            ActionDescriptor(id: "sidebar.chat.togglePin", title: t("action.sidebar.chat.togglePin", "Pin/Unpin Chat"),
                             keywords: ["sidebar", "chat", "history", "earlier", "pin", "unpin"], category: .sidebar, symbol: "pin",
                             surfaces: [.keyboard], targets: [.sidebarItem],
                             surfacePlan: plan(cli: .exempt(.guiOnly), exemption: .liveInput, palette: .exempt(.liveInput))),
            ActionDescriptor(
                id: "sidebar.item.add", title: t("action.sidebar.item.add", "Add to Sidebar…"),
                keywords: ["sidebar", "section", "pin", "settings", "account", "history", "bookmarks", "notifications"],
                category: .sidebar, symbol: "plus.app", surfaces: [.palette, .keyboard, .contextMenu],
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
                id: "sidebar.item.hideApp", title: t("action.sidebar.item.hideApp", "Hide App"),
                keywords: ["sidebar", "app", "hide", "extension"], category: .sidebar, symbol: "xmark.app",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem, .sidebarSection], cliName: "sidebar hide-app",
                // Offered on app items and app sections only (SidebarBridge
                // filters the menus); the app comes from the target. The menus
                // read Hide App, apart from a section's Hide Section (cmuxterm-hq#2015).
                surfacePlan: plan(menus: [p(.sidebarItem, .close, 120, label: ObjectMenuLabels.hideApp),
                                          p(.sidebarSection, .close, 110, label: ObjectMenuLabels.hideApp)])
            ),
            // A link, tab or app row: Archive keeps it in its group (or section), last and dimmed (archiving-DESIGN.md).
            ActionDescriptor(
                id: "sidebar.item.toggleArchive", title: t("action.sidebar.item.toggleArchive", "Archive/Unarchive Item"),
                keywords: ["sidebar", "item", "link", "tab", "archive", "unarchive", "dim"], category: .sidebar, symbol: "archivebox",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem], cliName: "sidebar toggle-item-archive",
                surfacePlan: plan(menus: [p(.sidebarItem, .identity, 110)])
            ),
            ActionDescriptor(
                id: "sidebar.item.toggleLabel", title: t("action.sidebar.item.toggleLabel", "Show/Hide Label"),
                keywords: ["sidebar", "item", "label", "icon", "title"], category: .sidebar, symbol: "textformat",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem], cliName: "sidebar toggle-item-label",
                surfacePlan: plan(menus: [p(.sidebarItem, .identity, 100, label: ObjectMenuLabels.toggleItemLabel)])
            ),
        ]
    }

    private static func sections() -> [ActionDescriptor] {
        let section: [ActionTargetKind] = [.sidebarSection]
        return [
            ActionDescriptor(
                id: "sidebar.section.add", title: t("action.sidebar.section.add", "New Section…"),
                keywords: ["sidebar", "section", "new", "add", "shelf"], category: .sidebar, symbol: "text.badge.plus",
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
            // No Move Section to Bottom: the sidebar has no bottom area (cx-n0i9), so a section
            // after the workspaces would not draw; Move to Top and Move to Scrolling Area are the moves.
            ActionDescriptor(
                id: "sidebar.section.useBuiltInLook", title: t("action.sidebar.section.useBuiltInLook", "Built-in Look"),
                keywords: ["sidebar", "section", "look", "style", "chrome", "built-in"], category: .sidebar, symbol: "house",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar section-look-built-in",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 200, folder: .appearance)])
            ),
            ActionDescriptor(
                id: "sidebar.section.useListLook", title: t("action.sidebar.section.useListLook", "List Look"),
                keywords: ["sidebar", "section", "look", "style", "list", "rows"], category: .sidebar, symbol: "list.bullet.rectangle",
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
                id: "sidebar.section.toggleTitle", title: t("action.sidebar.section.toggleTitle", "Show/Hide Section Title"),
                keywords: ["sidebar", "section", "title", "label", "header", "hide", "show"], category: .sidebar, symbol: "textformat",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar toggle-section-title",
                surfacePlan: plan(menus: [p(.sidebarSection, .identity, 220, folder: .appearance, label: ObjectMenuLabels.toggleSectionTitle)])
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
                id: "sidebar.section.toggleCollapsed", title: t("action.sidebar.section.toggleCollapsed", "Collapse/Expand Section"),
                keywords: ["sidebar", "section", "collapse", "expand", "fold"], category: .sidebar, symbol: "chevron.down",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section,
                // Collapse is per-window view state; scripts reach it by id.
                surfacePlan: plan(cli: .exempt(.focusMove), menus: [p(.sidebarSection, .organize, 100, label: ObjectMenuLabels.toggleSectionCollapsed)])
            ),
            ActionDescriptor(
                id: "sidebar.section.remove", title: t("action.sidebar.section.remove", "Remove Section"),
                keywords: ["sidebar", "section", "remove", "delete"], category: .sidebar, symbol: "trash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar remove-section",
                destructive: true, surfacePlan: plan(menus: [p(.sidebarSection, .close, 200)])
            ),
            // The open workspaces the section lists (Pinned too; the workspaces
            // section: its window's list); the section and its items stay.
            ActionDescriptor(
                id: "sidebar.section.closeWorkspaces", title: t("action.sidebar.section.closeWorkspaces", "Close All Workspaces in Section"),
                keywords: ["sidebar", "section", "pinned", "close", "workspaces", "all"], category: .sidebar, symbol: "xmark.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar close-section-workspaces",
                destructive: true, surfacePlan: plan(menus: [p(.sidebarSection, .close, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.section.newWorkspace", title: t("action.sidebar.section.newWorkspace", "New Workspace in Section"),
                keywords: ["sidebar", "section", "pinned", "new", "workspace", "create"], category: .sidebar, symbol: "plus.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: section, cliName: "sidebar new-section-workspace",
                surfacePlan: plan(menus: [p(.sidebarSection, .create, 105)])
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
            // Leo (cx-wab7m): the bottom band's pieces hide the macOS way, Hide on the piece's
            // own menu and Show on the band's (`sidebar.showSpaces`, `sidebar.showProfileControl`).
            ActionDescriptor(
                id: "sidebar.spaces.hide", title: t("action.sidebar.spaces.hide", "Hide Spaces"),
                keywords: ["sidebar", "spaces", "dots", "hide", "footer"], category: .sidebar, symbol: "eye.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.profile], cliName: "sidebar hide-spaces",
                surfacePlan: plan(menus: [p(.profile, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.spaces.show", title: t("action.sidebar.spaces.show", "Show Spaces"),
                keywords: ["sidebar", "spaces", "dots", "show", "unhide", "footer"], category: .sidebar, symbol: "circle.grid.2x2",
                surfaces: [.palette, .keyboard, .contextMenu], cliName: "sidebar show-spaces",
                surfacePlan: plan(menus: [p(.sidebarFooter, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.profileControl.hide", title: t("action.sidebar.profileControl.hide", "Hide Profile Button"),
                keywords: ["sidebar", "profile", "account", "avatar", "hide", "footer"], category: .sidebar, symbol: "person.crop.circle.badge.xmark",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.sidebarItem],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarItem, .view, 100)])
            ),
            ActionDescriptor(
                id: "sidebar.profileControl.show", title: t("action.sidebar.profileControl.show", "Show Profile Button"),
                keywords: ["sidebar", "profile", "account", "avatar", "show", "unhide", "footer"], category: .sidebar, symbol: "person.crop.circle",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarFooter, .view, 110)])
            ),
            // `sidebar.noFade` (Lawrence 2026-10-26): the whole list shows with no edge fade, and the
            // profile and search bar hides. Cmd+Shift+P shows the one that applies. In the sidebar
            // menu they sit in Options, so the top level keeps at most 12 rows; their icons differ from
            // the Minimal Mode rows beside them (one icon per row in a menu).
            ActionDescriptor(
                id: "sidebar.noFade.on", title: t("action.sidebar.noFade.on", "Show Whole Sidebar (No Fade)"),
                keywords: ["sidebar", "fade", "whole", "full", "everything", "edges", "profile", "search", "footer", "show", "hide"],
                category: .sidebar, symbol: "arrow.up.and.down",
                surfaces: [.palette, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 135, folder: .options)])
            ),
            ActionDescriptor(
                id: "sidebar.noFade.off", title: t("action.sidebar.noFade.off", "Restore Sidebar Fade"),
                keywords: ["sidebar", "fade", "restore", "edges", "profile", "search", "footer", "show", "unhide"],
                category: .sidebar, symbol: "rectangle.dashed",
                surfaces: [.palette, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 136, folder: .options)])
            ),
            // `sidebar.controlsOnHover` (Show Sidebar Controls Only on Hover, Lawrence 2026-10-27): the sidebar's controls show
            // only while the pointer is over it. Cmd+Shift+P, `cmux sidebar ...` and MCP show the one that applies.
            ActionDescriptor(
                id: "sidebar.controlsOnHover.on", title: t("action.sidebar.controlsOnHover.on", "Show Sidebar Controls Only on Hover"),
                keywords: ["sidebar", "minimal", "hover", "hide", "controls", "buttons", "search", "profile", "spaces", "footer", "clean"],
                category: .sidebar, symbol: "cursorarrow.rays",
                surfaces: [.palette, .contextMenu], cliName: "sidebar hide-controls-until-hover",
                surfacePlan: plan(menus: [p(.sidebarBackground, .view, 137, folder: .options)])
            ),
            ActionDescriptor(
                id: "sidebar.controlsOnHover.off", title: t("action.sidebar.controlsOnHover.off", "Always Show Sidebar Controls"),
                keywords: ["sidebar", "minimal", "hover", "show", "always", "controls", "buttons", "search", "profile", "spaces", "footer"],
                category: .sidebar, symbol: "rectangle",
                surfaces: [.palette, .contextMenu], cliName: "sidebar show-controls-always",
                surfacePlan: plan(menus: [p(.sidebarBackground, .view, 138, folder: .options)])
            ),
            // Leo (2026-10-06): Group ▸ in the sidebar's menu picks how the
            // Projects list buckets its loose rows (`sidebar.groupBy`).
            ActionDescriptor(
                id: "sidebar.groupBy.none", title: t("action.sidebar.groupBy.none", "Group by None"),
                keywords: ["sidebar", "projects", "group", "ungroup", "none", "flat"], category: .sidebar, symbol: "list.bullet",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .organize, 110, folder: .group)])
            ),
            ActionDescriptor(
                id: "sidebar.groupBy.folder", title: t("action.sidebar.groupBy.folder", "Group by Folder"),
                keywords: ["sidebar", "projects", "group", "folder", "directory", "cwd"], category: .sidebar, symbol: "folder",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .organize, 111, folder: .group)])
            ),
            // cx-13w3: compact (one line), comfortable (one line, taller) or expanded
            // (T3 Code / Codex style) workspace rows (`sidebar.density`); the sidebar background
            // menu owns these global controls, while the row's ⋮ keeps its pointer menu focused.
            // (Leo 2026-10-21: view toggles should not need the palette to find). The app density
            // (`appearance.density`, DensityActionCatalog) owns the palette's density rows.
            ActionDescriptor(
                id: "sidebar.density.compact", title: t("action.sidebar.density.compact", "Sidebar Density: Compact"),
                keywords: ["sidebar", "density", "compact", "rows", "one line", "dense"], category: .sidebar, symbol: "list.dash",
                // Not in the palette: "Density: Compact" (appearance.density.compact) is the one
                // palette row for "compact" (Lawrence 2026-10-20: two rows, and Enter did nothing).
                surfaces: [.keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly),
                                  menus: [p(.sidebarBackground, .view, 132, folder: .options, label: ObjectMenuLabels.densityCompact)],
                                  palette: .exempt(.familyMember))
            ),
            ActionDescriptor(
                id: "sidebar.density.comfortable", title: t("action.sidebar.density.comfortable", "Sidebar Density: Comfortable"),
                keywords: ["sidebar", "density", "comfortable", "rows", "one line", "taller", "spacious", "medium", "roomy"],
                category: .sidebar, symbol: "list.bullet", surfaces: [.keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly),
                                  menus: [p(.sidebarBackground, .view, 133, folder: .options, label: ObjectMenuLabels.densityComfortable)],
                                  palette: .exempt(.familyMember))
            ),
            ActionDescriptor(
                id: "sidebar.density.expanded", title: t("action.sidebar.density.expanded", "Sidebar Density: Expanded"),
                keywords: ["sidebar", "density", "expanded", "rows", "preview", "two lines", "t3", "codex"], category: .sidebar,
                symbol: "list.bullet.below.rectangle", surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly),
                                  menus: [p(.sidebarBackground, .view, 134, folder: .options, label: ObjectMenuLabels.densityExpanded)])
            ),
            // Leo (2026-10-09): the sidebar's menu checks Show Tabs Under
            // Workspaces (`sidebar.showWorkspaceTabs`; scripts set that), in
            // Options; the workspace row's ⋮ keeps its pointer menu focused.
            ActionDescriptor(
                id: "sidebar.workspaceTabs.toggle", title: t("action.sidebar.workspaceTabs.toggle", "Show Tabs Under Workspaces"),
                keywords: ["sidebar", "tabs", "workspace", "show", "list", "nested", "children"], category: .sidebar, symbol: "list.bullet.indent",
                surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 120, folder: .options)])
            ),
            ActionDescriptor(
                id: "sidebar.edit", title: t("action.sidebar.edit", "Edit Sidebar"), keywords: ["sidebar", "edit", "arrange", "reorder", "move", "remove",
                    "add", "items", "wiggle", "home screen"], category: .sidebar, symbol: "square.and.pencil", surfaces: [.palette, .keyboard, .contextMenu],
                surfacePlan: plan(cli: .exempt(.guiOnly), menus: [p(.sidebarBackground, .view, 119, folder: .options), p(.sidebarItem, .view, 120)])
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
            ("chief", t("argument.sidebar.builtin.chief", "Chief")),
            ("customize", t("argument.sidebar.builtin.customize", "Customize Appearance")),
        ]
        // Free text with the built-ins offered: `workspace:<id>` and
        // `app:<publisher>/<name>` put any workspace or app in the top rows
        // (PINNED-ITEMS-END-TO-END P1); an http(s) address adds a link.
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

    private static func p(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int, folder: MenuFolder? = nil,
                          label: String? = nil) -> ContextMenuPlacement {
        ContextMenuPlacement(context, group, rank, folder: folder, label: label)
    }

    private static func plan(cli: SurfaceDecision = .offered, menus: [ContextMenuPlacement] = [],
                             exemption: SurfaceExemption? = nil, palette: SurfaceDecision = .offered) -> ActionSurfacePlan {
        ActionSurfacePlan(palette: palette, cli: cli, contextMenus: menus, contextMenuExemption: menus.isEmpty ? exemption : nil)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "SidebarSectionActions", bundle: .module)
    }
}
