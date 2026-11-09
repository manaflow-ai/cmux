// The window dock (user 2026-11-05): a dock region of the window frame (plans/cmux-next/docked-workspace-DESIGN.md)
// that any pane moves into and out of, with the Home Chief pane's no-tab-bar mode per dock. The Chief window dock
// panel is apart from it: Show/Hide Chief (Cmd-I) shows or hides the Chief floating over the workspace (or docked,
// once the person docked it), never over Home; Undock Chief floats a docked one (cmux#37372). Titles live in
// LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func windowDockActions() -> [ActionDescriptor] {
        let window: [ActionTargetKind] = [.window]
        let edgeKeywords = ["window", "dock", "edge", "move", "chief", "frame"]
        return [
            row("home.openChiefDock", String(localized: "action.home.openChiefDock", defaultValue: "Show/Hide Chief", table: "LayoutActions", bundle: .module),
                .window, "sidebar.left", cli: "home open-chief-dock",
                keywords: ["chief", "dock", "window", "home", "chat", "float", "panel", "show", "hide", "toggle", "focus", "open"], targets: window,
                defaultShortcut: Shortcut("i", modifiers: [.command]), surfaces: [.palette, .keyboard]),
            row("home.undockChief", String(localized: "action.home.undockChief", defaultValue: "Undock Chief", table: "LayoutActions", bundle: .module),
                .window, "sidebar.left", cli: "home undock-chief",
                keywords: ["chief", "dock", "undock", "unpin", "float", "panel", "window", "home", "chat", "side", "left"], targets: window),
            {
                // Show/Hide Chief's system-wide key (user 2026-11-07), its own action so it has its own recorder in
                // Settings > Keyboard Shortcuts. Option-Shift-Space: free in cmux's defaults and macOS's reserved keys.
                var anyApp = ActionDescriptor(
                    id: "home.showHideChiefFromAnyApp",
                    title: String(localized: "action.home.showHideChiefFromAnyApp", defaultValue: "Show/Hide Chief from Any App", table: "LayoutActions", bundle: .module),
                    keywords: ["chief", "float", "panel", "show", "hide", "toggle", "global", "hotkey", "hot key", "any app", "summon"],
                    defaultShortcut: Shortcut(Shortcut.spaceKey, modifiers: [.option, .shift]),
                    category: .window, symbol: "bubble.left", surfaces: [.keyboard],
                    // Show/Hide Chief is the palette row and the CLI verb.
                    surfacePlan: ActionSurfacePlan(palette: .exempt(.familyMember), cli: .exempt(.familyMember), contextMenuExemption: .noObject))
                anyApp.isGlobalHotKey = true
                // It pulls cmux in front of the person's app: only a person presses it.
                anyApp.isPersonOnly = true
                return anyApp
            }(),
            row("window.movePaneToDock", String(localized: "action.window.movePaneToDock", defaultValue: "Move Pane to Dock", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.lefthalf.inset.filled.arrow.left", cli: "pane move-to-dock",
                keywords: ["pane", "dock", "window", "move", "pin", "side", "frame"], targets: [.pane]),
            row("window.toggleDock", String(localized: "action.window.toggleDock", defaultValue: "Show/Hide Dock", table: "LayoutActions", bundle: .module),
                .window, "sidebar.squares.left", cli: "window toggle-dock",
                keywords: ["window", "dock", "show", "hide", "toggle", "chief", "frame"], targets: window),
            row("window.toggleDockTabBar", String(localized: "action.window.toggleDockTabBar", defaultValue: "Show/Hide Dock Tab Bar", table: "LayoutActions", bundle: .module),
                .window, "menubar.rectangle", cli: "window toggle-dock-tab-bar",
                keywords: ["window", "dock", "tab bar", "tabs", "strip", "hide", "show", "chief"], targets: window),
            row("window.focusDock", String(localized: "action.window.focusDock", defaultValue: "Focus Dock", table: "LayoutActions", bundle: .module),
                .window, "scope", cli: "window focus-dock",
                keywords: ["window", "dock", "focus", "go", "chief", "jump"], targets: window),
            row("window.dockEdgeLeft", String(localized: "action.window.dockEdgeLeft", defaultValue: "Move Dock to Left", table: "LayoutActions", bundle: .module),
                .window, "rectangle.leftthird.inset.filled", cli: "window dock-edge-left", keywords: edgeKeywords + ["left"], targets: window),
            row("window.dockEdgeRight", String(localized: "action.window.dockEdgeRight", defaultValue: "Move Dock to Right", table: "LayoutActions", bundle: .module),
                .window, "rectangle.rightthird.inset.filled", cli: "window dock-edge-right", keywords: edgeKeywords + ["right"], targets: window),
            row("window.dockEdgeTop", String(localized: "action.window.dockEdgeTop", defaultValue: "Move Dock to Top", table: "LayoutActions", bundle: .module),
                .window, "rectangle.topthird.inset.filled", cli: "window dock-edge-top", keywords: edgeKeywords + ["top"], targets: window),
            row("window.dockEdgeBottom", String(localized: "action.window.dockEdgeBottom", defaultValue: "Move Dock to Bottom", table: "LayoutActions", bundle: .module),
                .window, "rectangle.bottomthird.inset.filled", cli: "window dock-edge-bottom", keywords: edgeKeywords + ["bottom"], targets: window),
        ]
    }
}
