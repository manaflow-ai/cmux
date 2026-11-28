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
            ActionDescriptor(
                id: "browserStop",
                title: String(localized: "action.browserStop", defaultValue: "Stop Loading", bundle: .module),
                keywords: ["browser", "cancel", "halt"], defaultShortcut: Shortcut(".", modifiers: [.command]),
                category: .browser, symbol: "xmark", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser stop-loading", mainMenu: .view,
                // The reload button is Stop while a page loads: the page
                // menu's Reload Page is the same control.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .familyMember)
            ),
            ActionDescriptor(
                id: "browser.copyURL",
                title: String(localized: "action.browser.copyURL", defaultValue: "Copy Page URL", bundle: .module),
                keywords: ["browser", "link", "address", "url", "clipboard", "share"],
                defaultShortcut: Shortcut("c", modifiers: [.command, .shift]), category: .browser, symbol: "link",
                surfaces: [.palette, .keyboard, .contextMenu], requires: [.browserFocused], targets: [.tab],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.clipboard), contextMenus: [ActionSurfaceCatalog.p(.browserPage, .navigate, 4)])
            ),
            // Shift-Cmd-G is Find Previous in every Mac browser. Elsewhere the
            // chord stays Group Selected Workspaces: this binding needs a
            // browser focused, so it wins only there (specificity rule).
            ActionDescriptor(
                id: "browser.findPrevious",
                title: String(localized: "action.browser.findPrevious", defaultValue: "Find Previous in Page", bundle: .module),
                keywords: ["browser", "search", "find"], defaultShortcut: Shortcut("g", modifiers: [.command, .shift]),
                category: .browser, symbol: "chevron.up.circle", surfaces: [.keyboard], requires: [.browserFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.familyMember), cli: .exempt(.familyMember), contextMenuExemption: .familyMember)
            ),
            // The prompt bar's permission question (automatic downloads,
            // camera, microphone) answered without the mouse: the keyboard
            // path, the palette, and `action.run` for scripts and proofs.
            // It answers the live question in the focused tab only.
            // The blocked-download notice's Site Settings… button: the site
            // that blocked the newest download, where its choice changes.
            ActionDescriptor(
                id: "browser.download.openBlockedSiteSettings",
                title: String(localized: "action.browser.download.openBlockedSiteSettings", defaultValue: "Open Site Settings of Blocked Download", bundle: .module),
                keywords: ["browser", "download", "blocked", "automatic downloads", "multiple files", "site settings", "permission", "allow"],
                category: .browser, symbol: "gearshape", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "browser.prompt.allow",
                title: String(localized: "action.browser.prompt.allow", defaultValue: "Allow Site Request", bundle: .module),
                keywords: ["browser", "permission", "prompt", "allow", "download", "multiple files", "camera", "microphone"],
                category: .browser, symbol: "checkmark.circle", surfaces: [.palette], requires: [.browserFocused], targets: [.tab],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.liveInput), contextMenuExemption: .liveInput)
            ),
            ActionDescriptor(
                id: "browser.prompt.block",
                title: String(localized: "action.browser.prompt.block", defaultValue: "Block Site Request", bundle: .module),
                keywords: ["browser", "permission", "prompt", "block", "deny", "never allow", "download", "camera", "microphone"],
                category: .browser, symbol: "nosign", surfaces: [.palette], requires: [.browserFocused], targets: [.tab],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.liveInput), contextMenuExemption: .liveInput)
            ),
        ]
    }
}
