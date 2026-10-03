// App platform (plans/cmux-next/app-platform.md section 3): the App Store
// window. Titles live in AppStoreActions.xcstrings. Install and remove are
// window buttons only (Lawrence 2026-10-02: no agent installs until the
// actor stamp), so there is no install action; `appStore.show` with `app`
// may open a listing but never installs.

nonisolated enum AppStoreActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "appStore.show", title: t("action.appStore.show", "App Store"),
                keywords: ["apps", "store", "extensions", "plugins", "install", "marketplace", "sidebar sections"],
                category: .settings, symbol: "bag", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [ActionArgument(name: "app", title: t("argument.appStore.app", "App"), kind: .string, isRequired: false)],
                surfacePlan: ActionSurfacePlan(
                    // A window for a person to browse; agents read listings
                    // through the store ops (`apps search|info`) instead.
                    cli: .exempt(.guiOnly),
                    contextMenus: [ContextMenuPlacement(.sidebarBackground, .view, 301)])
            ),
            ActionDescriptor(
                id: "appStore.showInstalled", title: t("action.appStore.showInstalled", "Installed Apps"),
                keywords: ["apps", "installed", "extensions", "plugins", "permissions", "logs", "reload", "disable"],
                category: .settings, symbol: "bag.badge.checkmark", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // Hide is a per-user view preference (app-platform.md V9): the app keeps running
            // and answering granted calls; it only leaves the sidebar, palette and menus.
            // The sidebar's own `sidebar.item.hideApp` forwards here; the App Store has buttons.
            ActionDescriptor(
                id: "app.hide", title: t("action.app.hide", "Hide App"),
                keywords: ["apps", "hide", "remove from sidebar", "declutter"],
                category: .settings, symbol: "eye.slash", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "app", title: t("argument.appStore.app", "App"), kind: .string)],
                cliName: "apps hide",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "app.unhide", title: t("action.app.unhide", "Show Hidden App"),
                keywords: ["apps", "unhide", "show", "hidden", "restore"],
                category: .settings, symbol: "eye", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "app", title: t("argument.appStore.app", "App"), kind: .string)],
                cliName: "apps unhide",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // Runs a command an app contributes (`contributes.commands`). With no
            // arguments it opens a palette page of the visible apps' commands.
            ActionDescriptor(
                id: "app.command.run", title: t("action.app.command.run", "Run App Command…"),
                keywords: ["apps", "command", "coderouter", "status", "accounts", "usage", "route"],
                category: .settings, symbol: "puzzlepiece.extension", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "app", title: t("argument.appStore.app", "App"), kind: .string, isRequired: false),
                            ActionArgument(name: "command", title: t("argument.app.command", "Command"), kind: .string, isRequired: false)],
                cliName: "app run-command",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "AppStoreActions", bundle: .module)
    }
}
