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
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "AppStoreActions", bundle: .module)
    }
}
