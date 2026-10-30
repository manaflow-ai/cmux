// The browser toolbar's menu buttons (media hub, Downloads, design mode,
// profile, theme, DevTools, More; plans/cmux-next R80, cx-6qwm). Design mode, theme and
// DevTools run `toggleBrowserDesignMode`, `browserTheme` and
// `toggleBrowserDeveloperTools` (one action id per behavior); these four open
// the media hub, downloads, profile and More menus at their buttons. Titles live in BrowserToolbarActions.xcstrings.

nonisolated enum BrowserToolbarActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
            String(localized: key, defaultValue: value, table: "BrowserToolbarActions", bundle: .module)
        }
        // A menu at a toolbar button: nothing to script, and every item is
        // its own action with its own CLI verb and right-click placement.
        let plan = ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
        return [
            ActionDescriptor(
                id: "browser.media.show",
                title: text("action.browser.media.show", "Show Media Controls…"),
                keywords: ["browser", "media", "music", "video", "now playing", "play", "pause", "toolbar"], category: .browser,
                symbol: "music.note", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser media", surfacePlan: plan
            ),
            ActionDescriptor(
                id: "browser.downloads.show",
                title: text("action.browser.downloads.show", "Show Downloads…"),
                keywords: ["browser", "downloads", "files", "progress", "toolbar"], category: .browser,
                symbol: "arrow.down.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser downloads", surfacePlan: plan
            ),
            ActionDescriptor(
                id: "browser.profile.choose",
                title: text("action.browser.profile.choose", "Choose Browser Profile…"),
                keywords: ["browser", "profile", "person", "account", "switch", "toolbar"], category: .browser,
                symbol: "person.crop.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser choose-profile", surfacePlan: plan
            ),
            ActionDescriptor(
                id: "browser.overflow.menu",
                title: text("action.browser.overflow.menu", "More Browser Actions…"),
                keywords: ["browser", "more", "overflow", "menu", "toolbar", "ellipsis"], category: .browser,
                symbol: "ellipsis", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser more-actions", surfacePlan: plan
            ),
        ]
    }
}
