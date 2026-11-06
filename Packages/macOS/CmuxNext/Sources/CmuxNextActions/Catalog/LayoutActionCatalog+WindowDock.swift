// The window dock (user 2026-11-05): a dock region of the window frame (plans/cmux-next/docked-workspace-DESIGN.md)
// that any pane moves into and out of, with the Home Chief pane's no-tab-bar mode per dock. The Chief window dock
// is one: Open Chief Dock (Cmd-I) docks Home's Chief at `home.chiefDock.edge` and focuses it. Titles live in
// LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func windowDockActions() -> [ActionDescriptor] {
        let window: [ActionTargetKind] = [.window]
        let edgeKeywords = ["window", "dock", "edge", "move", "chief", "frame"]
        return [
            row("home.openChiefDock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.home.openChiefDock") + "\u{E002}" + String(localized: "action.home.openChiefDock", defaultValue: "Open Chief Dock", table: "LayoutActions", bundle: .module)),
                .window, "sidebar.left", cli: "home open-chief-dock",
                keywords: ["chief", "dock", "window", "home", "chat", "side", "left", "focus", "open"], targets: window,
                defaultShortcut: Shortcut("i", modifiers: [.command]), surfaces: [.palette, .keyboard]),
            row("window.movePaneToDock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.movePaneToDock") + "\u{E002}" + String(localized: "action.window.movePaneToDock", defaultValue: "Move Pane to Dock", table: "LayoutActions", bundle: .module)),
                .pane, "rectangle.lefthalf.inset.filled.arrow.left", cli: "pane move-to-dock",
                keywords: ["pane", "dock", "window", "move", "pin", "side", "frame"], targets: [.pane]),
            row("window.toggleDock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDock") + "\u{E002}" + String(localized: "action.window.toggleDock", defaultValue: "Show/Hide Dock", table: "LayoutActions", bundle: .module)),
                .window, "sidebar.squares.left", cli: "window toggle-dock",
                keywords: ["window", "dock", "show", "hide", "toggle", "chief", "frame"], targets: window),
            row("window.toggleDockTabBar", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockTabBar") + "\u{E002}" + String(localized: "action.window.toggleDockTabBar", defaultValue: "Show/Hide Dock Tab Bar", table: "LayoutActions", bundle: .module)),
                .window, "menubar.rectangle", cli: "window toggle-dock-tab-bar",
                keywords: ["window", "dock", "tab bar", "tabs", "strip", "hide", "show", "chief"], targets: window),
            row("window.focusDock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.focusDock") + "\u{E002}" + String(localized: "action.window.focusDock", defaultValue: "Focus Dock", table: "LayoutActions", bundle: .module)),
                .window, "scope", cli: "window focus-dock",
                keywords: ["window", "dock", "focus", "go", "chief", "jump"], targets: window),
            row("window.dockEdgeLeft", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.dockEdgeLeft") + "\u{E002}" + String(localized: "action.window.dockEdgeLeft", defaultValue: "Move Dock to Left", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.leftthird.inset.filled", cli: "window dock-edge-left", keywords: edgeKeywords + ["left"], targets: window),
            row("window.dockEdgeRight", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.dockEdgeRight") + "\u{E002}" + String(localized: "action.window.dockEdgeRight", defaultValue: "Move Dock to Right", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.rightthird.inset.filled", cli: "window dock-edge-right", keywords: edgeKeywords + ["right"], targets: window),
            row("window.dockEdgeTop", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.dockEdgeTop") + "\u{E002}" + String(localized: "action.window.dockEdgeTop", defaultValue: "Move Dock to Top", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.topthird.inset.filled", cli: "window dock-edge-top", keywords: edgeKeywords + ["top"], targets: window),
            row("window.dockEdgeBottom", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.dockEdgeBottom") + "\u{E002}" + String(localized: "action.window.dockEdgeBottom", defaultValue: "Move Dock to Bottom", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.bottomthird.inset.filled", cli: "window dock-edge-bottom", keywords: edgeKeywords + ["bottom"], targets: window),
        ]
    }
}
