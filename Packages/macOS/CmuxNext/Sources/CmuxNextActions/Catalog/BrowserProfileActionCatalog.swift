// Browser profiles (plans/cmux-next/data-model.md 5 and 7): separate cookie
// jars, logins, history, extensions and site permissions, chosen per tab.
// Titles live in BrowserProfileActions.xcstrings. Every action is in the
// palette and the CLI (`cmux browser-profile ...`) and can take a shortcut;
// none has a default shortcut.

nonisolated enum BrowserProfileActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let keywords = ["browser", "profile", "chrome", "cookies", "account", "person"]
        func descriptor(
            _ id: ActionID, _ title: String, _ symbol: String, _ cli: String, extra: [String] = [],
            arguments: [ActionArgument] = [], targets: [ActionTargetKind] = [.browserProfile],
            surfaces: ActionSurfaces = [.palette, .keyboard, .contextMenu], destructive: Bool = false
        ) -> ActionDescriptor {
            ActionDescriptor(id: id, title: title, keywords: keywords + extra, category: .browser, symbol: symbol,
                             surfaces: surfaces, arguments: arguments, targets: targets, cliName: "browser-profile " + cli,
                             destructive: destructive)
        }
        func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
            String(localized: key, defaultValue: value, table: "BrowserProfileActions", bundle: .module)
        }
        let profile = CatalogArgument.browserProfile
        var deleteDescriptor = descriptor("browserProfile.delete", text("action.browserProfile.delete", "Delete Browser Profile and Its Data…"),
                                          "trash", "delete", extra: ["remove", "data"], destructive: true)
        // Only a person deletes a browser profile (its cookies, sign-ins, passwords and passkeys):
        // the control socket refuses every CLI, MCP or script run, and a page needs the person's
        // own click. The daemon refuses `delete-browser-profile` from any connection but the app.
        deleteDescriptor.isPersonOnly = true
        return [
            descriptor("browserProfile.new", text("action.browserProfile.new", "New Browser Profile…"), "person.crop.circle.badge.plus",
                       "create", extra: ["add", "create"],
                       arguments: [CatalogArgument.nameString.optional, CatalogArgument.colorChoice.optional, CatalogArgument.iconString.optional],
                       targets: [], surfaces: [.palette, .keyboard, .menu, .contextMenu]),
            descriptor("browserProfile.rename", text("action.browserProfile.rename", "Rename Browser Profile…"), "pencil", "rename",
                       extra: ["name"], arguments: [CatalogArgument.nameString.optional]),
            descriptor("browserProfile.setColor", text("action.browserProfile.setColor", "Set Browser Profile Color…"), "paintpalette",
                       "set-color", extra: ["color"], arguments: [CatalogArgument.colorChoice]),
            descriptor("browserProfile.clearColor", text("action.browserProfile.clearColor", "Remove Browser Profile Color"), "circle.slash",
                       "clear-color", extra: ["color", "reset", "clear"]),
            descriptor("browserProfile.setIcon", text("action.browserProfile.setIcon", "Set Browser Profile Icon…"), "face.smiling",
                       "set-icon", extra: ["icon", "emoji", "avatar"], arguments: [CatalogArgument.iconString.optional]),
            descriptor("browserProfile.clearIcon", text("action.browserProfile.clearIcon", "Remove Browser Profile Icon"), "circle.dashed",
                       "clear-icon", extra: ["icon", "reset", "clear"]),
            deleteDescriptor,
            descriptor("browserProfile.newTab", text("action.browserProfile.newTab", "New Tab with Browser Profile…"), "person.crop.square",
                       "new-tab", extra: ["tab", "open"], arguments: [profile, CatalogArgument.urlString.optional], targets: [.pane]),
            descriptor("browserProfile.newWindow", text("action.browserProfile.newWindow", "New Window with Browser Profile…"),
                       "macwindow.badge.plus", "new-window", extra: ["window"], arguments: [profile], targets: []),
            descriptor("browserProfile.newWorkspace", text("action.browserProfile.newWorkspace", "New Workspace with Browser Profile…"),
                       "plus.rectangle.on.rectangle", "new-workspace", extra: ["workspace"], arguments: [profile], targets: []),
            descriptor("browserProfile.openLink", text("action.browserProfile.openLink", "Open Link in Browser Profile…"), "link",
                       "open-link", extra: ["link", "url"], arguments: [profile, CatalogArgument.urlString], targets: [.pane]),
            descriptor("browserProfile.setWorkspaceDefault", text("action.browserProfile.setWorkspaceDefault", "Set Workspace Browser Profile…"),
                       "person.crop.rectangle", "set-workspace-default", extra: ["workspace", "default"], arguments: [profile],
                       targets: [.workspace]),
            descriptor("browserProfile.clearWorkspaceDefault", text("action.browserProfile.clearWorkspaceDefault", "Clear Workspace Browser Profile"),
                       "person.slash", "clear-workspace-default", extra: ["workspace", "default", "reset"],
                       targets: [.workspace]),
            descriptor("browserProfile.setSpaceDefault", text("action.browserProfile.setSpaceDefault", "Set Space Browser Profile…"),
                       "person.2.crop.square.stack", "set-space-default", extra: ["room", "default"], arguments: [profile],
                       targets: [.profile]),
            descriptor("browserProfile.clearSpaceDefault", text("action.browserProfile.clearSpaceDefault", "Clear Space Browser Profile"),
                       "person.2.slash", "clear-space-default", extra: ["room", "default", "reset"], targets: [.profile]),
            descriptor("browserProfile.moveTab", text("action.browserProfile.moveTab", "Move Tab to Browser Profile…"),
                       "arrow.right.square", "move-tab", extra: ["tab", "move", "reopen"], arguments: [profile], targets: [.tab]),
            descriptor("browserProfile.duplicateTab", text("action.browserProfile.duplicateTab", "Duplicate Tab into Browser Profile…"),
                       "plus.square.on.square", "duplicate-tab", extra: ["tab", "copy", "duplicate"], arguments: [profile], targets: [.tab]),
            // cx-d0d.23, Chrome's Clear Browsing Data: the profile's history, cookies and site data,
            // and cache over a time range the run names (every kind by default).
            descriptor("browserProfile.clearBrowsingData", text("action.browserProfile.clearBrowsingData", "Clear Browsing Data…"),
                       "eraser", "clear-browsing-data", extra: ["history", "cache", "privacy", "delete", "clear", "data"],
                       arguments: [HistoryActionCatalog.historyRange,
                                   CatalogArgument.clearKind("history", text("argument.browsingData.history", "Browsing History")),
                                   CatalogArgument.clearKind("cookies", text("argument.browsingData.cookies", "Cookies and Site Data")),
                                   CatalogArgument.clearKind("cache", text("argument.browsingData.cache", "Cached Images and Files"))],
                       targets: [.browserProfile], destructive: true),
            // Everything Import from Browser saved into the profile (pages, bookmarks, tabs), and its Keep in Sync.
            descriptor("browserProfile.removeImportedData", text("action.browserProfile.removeImportedData", "Remove Imported Browser Data…"),
                       "tray.and.arrow.down", "remove-imported-data", extra: ["import", "imported", "history", "bookmarks", "privacy", "delete"],
                       destructive: true),
            descriptor("browserProfile.manageExtensions", text("action.browserProfile.manageExtensions", "Manage Extensions in Browser Profile…"),
                       "puzzlepiece", "manage-extensions", extra: ["extension", "extensions", "addon"], arguments: [profile], targets: []),
        ]
    }
}

/// Arguments of the browser profile actions (BrowserProfileActions.xcstrings).
nonisolated extension CatalogArgument {
    /// A browser profile: `default` or its UUID (`--arg browserProfile=<id>`
    /// or `--target browser-profile:<id>`); the palette lists them by name.
    static var browserProfile: ActionArgument {
        ActionArgument(name: "browserProfile",
                       title: String(localized: "argument.browserProfile", defaultValue: "Browser Profile", table: "BrowserProfileActions", bundle: .module),
                       kind: .target(.browserProfile))
    }

    /// One kind of browsing data Clear Browsing Data clears (default on).
    static func clearKind(_ name: String, _ title: String) -> ActionArgument {
        ActionArgument(name: name, title: title, kind: .bool, isRequired: false)
    }
}
