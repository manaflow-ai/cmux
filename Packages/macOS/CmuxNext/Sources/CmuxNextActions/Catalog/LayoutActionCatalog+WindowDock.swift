// The window dock (user 2026-11-05): a dock region of the window frame (plans/cmux-next/docked-workspace-DESIGN.md)
// that any pane moves into and out of, with the Home Chief pane's no-tab-bar mode per dock. The Chief window dock
// is one: Open Chief Dock (Cmd-I) docks Home's Chief at `home.chiefDock.edge` and focuses it; Undock Chief
// (cmux#37372) sends it back to the sidebar. Titles live in
// LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func windowDockActions() -> [ActionDescriptor] {
        let window: [ActionTargetKind] = [.window]
        let edgeKeywords = ["window", "dock", "edge", "move", "chief", "frame"]
        return [
            row("home.openChiefDock", String(localized: "action.home.openChiefDock", defaultValue: "Open Chief Dock", table: "LayoutActions", bundle: .module),
                .window, "sidebar.left", cli: "home open-chief-dock",
                keywords: ["chief", "dock", "window", "home", "chat", "side", "left", "focus", "open"], targets: window,
                defaultShortcut: Shortcut("i", modifiers: [.command]), surfaces: [.palette, .keyboard]),
            row("home.undockChief", String(localized: "action.home.undockChief", defaultValue: "Undock Chief", table: "LayoutActions", bundle: .module),
                .window, "sidebar.left", cli: "home undock-chief",
                keywords: ["chief", "dock", "undock", "unpin", "window", "home", "chat", "side", "left", "close", "hide"], targets: window),
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
