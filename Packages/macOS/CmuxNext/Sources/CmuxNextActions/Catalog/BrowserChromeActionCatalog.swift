// Browser chrome actions (R88): the address bar's Return chords and the
// page chords every Mac browser has. Titles live in ActionCatalog.xcstrings
// (21 languages).

nonisolated enum BrowserChromeActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // Return chords of the address bar (Chrome, Safari). They act on
            // the text being edited, so only the keyboard reaches them; they
            // need the address bar focused, which makes them win over the
            // actions that share the chords elsewhere (Toggle Pane Zoom).
            ActionDescriptor(
                id: "omnibar.openInBackgroundTab",
                title: String(localized: "action.omnibar.openInBackgroundTab", defaultValue: "Open Address in New Background Tab", bundle: .module),
                keywords: ["browser", "url", "omnibox", "address bar", "new tab", "background"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command]), category: .browser,
                symbol: "plus.square.on.square", surfaces: [.keyboard], requires: [.omnibarFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.liveInput), contextMenuExemption: .liveInput)
            ),
            ActionDescriptor(
                id: "omnibar.openInForegroundTab",
                title: String(localized: "action.omnibar.openInForegroundTab", defaultValue: "Open Address in New Tab", bundle: .module),
                keywords: ["browser", "url", "omnibox", "address bar", "new tab", "foreground"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command, .shift]), category: .browser,
                symbol: "plus.square", surfaces: [.keyboard], requires: [.omnibarFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.liveInput), contextMenuExemption: .liveInput)
            ),
        ]
    }
}
