// Bookmarks (plans/cmux-next/bookmarks.md section 3). Titles live in
// BookmarkActions.xcstrings. Cmd-D stays Split Right (round 3 decision), so
// Bookmark This Page has no default chord; Cmd-Shift-B is free in cmux and
// toggles the bookmarks bar.

nonisolated enum BookmarkActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "bookmark.addPage", title: t("action.bookmark.addPage", "Bookmark This Page"),
                keywords: ["bookmark", "star", "favorite", "save", "page"], category: .browser, symbol: "star",
                surfaces: [.palette, .keyboard, .menu, .contextMenu], requires: [.browserFocused], targets: [.tab],
                cliName: "bookmark add-page", mainMenu: .view
            ),
            ActionDescriptor(
                id: "bookmark.addAllTabs", title: t("action.bookmark.addAllTabs", "Bookmark All Tabs…"),
                keywords: ["bookmark", "tabs", "folder", "save"], category: .browser, symbol: "star.square.on.square",
                surfaces: [.palette, .keyboard, .menu], arguments: [folderName(required: false)], targets: [.pane],
                cliName: "bookmark add-all-tabs", mainMenu: .view
            ),
            ActionDescriptor(
                id: "bookmark.add", title: t("action.bookmark.add", "Add Bookmark…"),
                keywords: ["bookmark", "new", "url"], category: .browser, symbol: "plus",
                surfaces: [.palette, .keyboard],
                arguments: [
                    ActionArgument(name: "url", title: t("argument.bookmark.url", "URL"), kind: .string),
                    ActionArgument(name: "title", title: t("argument.bookmark.title", "Name"), kind: .string, isRequired: false),
                    folder, profile,
                ],
                cliName: "bookmark add"
            ),
            ActionDescriptor(
                id: "bookmark.newFolder", title: t("action.bookmark.newFolder", "New Bookmark Folder…"),
                keywords: ["bookmark", "folder", "new"], category: .browser, symbol: "folder.badge.plus",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [folderName(required: true), folder, profile],
                cliName: "bookmark new-folder"
            ),
            ActionDescriptor(
                id: "bookmark.open", title: t("action.bookmark.open", "Open Bookmark…"),
                keywords: ["bookmark", "open", "go", "favorite", "search"], category: .browser, symbol: "book",
                surfaces: [.palette, .keyboard, .menu, .contextMenu], arguments: [query], targets: [.bookmark],
                cliName: "bookmark open", mainMenu: .view
            ),
            ActionDescriptor(
                id: "bookmark.openInNewTab", title: t("action.bookmark.openInNewTab", "Open Bookmark in New Tab"),
                keywords: ["bookmark", "tab"], category: .browser, symbol: "plus.square", surfaces: [.contextMenu],
                arguments: [query], targets: [.bookmark], cliName: "bookmark open-in-new-tab"
            ),
            ActionDescriptor(
                id: "bookmark.openInBackgroundTab", title: t("action.bookmark.openInBackgroundTab", "Open Bookmark in Background Tab"),
                keywords: ["bookmark", "tab", "background"], category: .browser, symbol: "square.on.square", surfaces: [.contextMenu],
                arguments: [query], targets: [.bookmark], cliName: "bookmark open-in-background-tab"
            ),
            ActionDescriptor(
                id: "bookmark.openAll", title: t("action.bookmark.openAll", "Open All Bookmarks in Folder"),
                keywords: ["bookmark", "folder", "tabs"], category: .browser, symbol: "square.stack", surfaces: [.contextMenu],
                arguments: [query], targets: [.bookmark], cliName: "bookmark open-all"
            ),
            ActionDescriptor(
                id: "bookmark.edit", title: t("action.bookmark.edit", "Edit Bookmark…"),
                keywords: ["bookmark", "rename", "url", "edit"], category: .browser, symbol: "pencil",
                surfaces: [.palette, .contextMenu],
                arguments: [query, ActionArgument(name: "title", title: t("argument.bookmark.title", "Name"), kind: .string, isRequired: false),
                            ActionArgument(name: "url", title: t("argument.bookmark.url", "URL"), kind: .string, isRequired: false)],
                targets: [.bookmark], cliName: "bookmark edit"
            ),
            ActionDescriptor(
                id: "bookmark.move", title: t("action.bookmark.move", "Move Bookmark…"),
                keywords: ["bookmark", "folder", "reorder", "move"], category: .browser, symbol: "arrow.up.arrow.down",
                surfaces: [.palette],
                arguments: [query, folder,
                            ActionArgument(name: "index", title: t("argument.bookmark.index", "Position"), kind: .int(0...100_000),
                                           isRequired: false)],
                targets: [.bookmark], cliName: "bookmark move"
            ),
            ActionDescriptor(
                id: "bookmark.remove", title: t("action.bookmark.remove", "Delete Bookmark"),
                keywords: ["bookmark", "delete", "remove", "unstar"], category: .browser, symbol: "trash",
                surfaces: [.palette, .contextMenu], arguments: [query], targets: [.bookmark], cliName: "bookmark remove"
            ),
            ActionDescriptor(
                id: "bookmark.toggleBar", title: t("action.bookmark.toggleBar", "Show Bookmarks Bar"),
                keywords: ["bookmark", "bar", "toolbar", "hide", "toggle", "favorites"],
                defaultShortcut: Shortcut("b", modifiers: [.command, .shift]), category: .browser, symbol: "menubar.rectangle",
                surfaces: [.palette, .keyboard, .menu, .contextMenu], cliName: "bookmark toggle-bar", mainMenu: .view
            ),
            ActionDescriptor(
                id: "bookmark.manager", title: t("action.bookmark.manager", "Bookmark Manager"),
                keywords: ["bookmark", "manager", "organize", "cmux://bookmarks", "library"], category: .browser,
                symbol: "book.closed", surfaces: [.palette, .keyboard, .menu, .contextMenu], cliName: "bookmark manager", mainMenu: .view
            ),
            ActionDescriptor(
                id: "bookmark.import", title: t("action.bookmark.import", "Import Bookmarks…"),
                keywords: ["bookmark", "import", "html", "netscape", "chrome", "safari", "firefox"], category: .browser,
                symbol: "square.and.arrow.down", surfaces: [.palette, .keyboard, .menu], arguments: [path, profile],
                cliName: "bookmark import", mainMenu: .file
            ),
            ActionDescriptor(
                id: "bookmark.importFromBrowser", title: t("action.bookmark.importFromBrowser", "Import Bookmarks from Browser…"),
                keywords: ["bookmark", "import", "browser", "chrome", "safari", "firefox", "arc", "brave", "edge", "dia", "zen", "helium", "comet"],
                category: .browser, symbol: "square.and.arrow.down.on.square", surfaces: [.palette, .keyboard, .menu],
                arguments: [
                    ActionArgument(name: "browser", title: t("argument.bookmark.browser", "Browser"), kind: .string, isRequired: false),
                    ActionArgument(name: "source", title: t("argument.bookmark.sourceProfile", "Profile to Import"), kind: .string,
                                   isRequired: false),
                    profile,
                ],
                cliName: "bookmark import-from-browser", mainMenu: .file
            ),
            ActionDescriptor(
                id: "bookmark.export", title: t("action.bookmark.export", "Export Bookmarks…"),
                keywords: ["bookmark", "export", "html", "netscape", "backup"], category: .browser, symbol: "square.and.arrow.up",
                surfaces: [.palette, .keyboard, .menu], arguments: [path, profile], cliName: "bookmark export", mainMenu: .file
            ),
        ]
    }

    /// A bookmark id, a URL or text naming one (the CLI's first word).
    private static var query: ActionArgument {
        ActionArgument(name: "bookmark", title: t("argument.bookmark.bookmark", "Bookmark"), kind: .string, isRequired: false)
    }

    private static var folder: ActionArgument {
        ActionArgument(name: "folder", title: t("argument.bookmark.folder", "Folder"), kind: .string, isRequired: false)
    }

    private static func folderName(required: Bool) -> ActionArgument {
        ActionArgument(name: "name", title: t("argument.bookmark.folderName", "Folder Name"), kind: .string, isRequired: required)
    }

    private static var profile: ActionArgument {
        ActionArgument(name: "profile", title: t("argument.bookmark.profile", "Browser Profile"), kind: .target(.browserProfile),
                       isRequired: false)
    }

    private static var path: ActionArgument {
        ActionArgument(name: "path", title: t("argument.bookmark.path", "File"), kind: .string, isRequired: false)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "BookmarkActions", bundle: .module)
    }
}
