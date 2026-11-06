// Docked workspaces: the window frame (plans/cmux-next/docked-workspace-DESIGN.md). Debug Settings
// `window.dockedWorkspaces` turns them on; off, each action refuses with that reason. Titles live in
// LayoutActions.xcstrings. No default shortcuts.

nonisolated extension LayoutActionCatalog {
    static func dockedWorkspaceActions() -> [ActionDescriptor] {
        let workspace: [ActionTargetKind] = [.workspace]
        return [
            row("workspace.dockLeft", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.dockLeft") + "\u{E002}" + String(localized: "action.workspace.dockLeft", defaultValue: "Dock Workspace Left", table: "LayoutActions", bundle: .module)),
                .workspace, "rectangle.leftthird.inset.filled", cli: "workspace dock-left", keywords: ["workspace", "dock", "pin", "window", "left", "frame"], targets: workspace),
            row("workspace.dockRight", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.dockRight") + "\u{E002}" + String(localized: "action.workspace.dockRight", defaultValue: "Dock Workspace Right", table: "LayoutActions", bundle: .module)),
                .workspace, "rectangle.rightthird.inset.filled", cli: "workspace dock-right", keywords: ["workspace", "dock", "pin", "window", "right", "frame"], targets: workspace),
            row("workspace.dockTop", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.dockTop") + "\u{E002}" + String(localized: "action.workspace.dockTop", defaultValue: "Dock Workspace Top", table: "LayoutActions", bundle: .module)),
                .workspace, "rectangle.topthird.inset.filled", cli: "workspace dock-top", keywords: ["workspace", "dock", "pin", "window", "top", "frame"], targets: workspace),
            row("workspace.dockBottom", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.dockBottom") + "\u{E002}" + String(localized: "action.workspace.dockBottom", defaultValue: "Dock Workspace Bottom", table: "LayoutActions", bundle: .module)),
                .workspace, "rectangle.bottomthird.inset.filled", cli: "workspace dock-bottom", keywords: ["workspace", "dock", "pin", "window", "bottom", "panel", "frame"], targets: workspace),
            row("workspace.undock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.undock") + "\u{E002}" + String(localized: "action.workspace.undock", defaultValue: "Undock Workspace", table: "LayoutActions", bundle: .module)),
                .workspace, "pin.slash", cli: "workspace undock", keywords: ["workspace", "undock", "unpin", "window", "frame"], targets: workspace),
            row("workspace.toggleDockFloating", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.workspace.toggleDockFloating") + "\u{E002}" + String(localized: "action.workspace.toggleDockFloating", defaultValue: "Float Docked Workspace", table: "LayoutActions", bundle: .module)),
                .workspace, "square.on.square", cli: "workspace toggle-dock-floating", keywords: ["workspace", "dock", "float", "floating", "overlay", "drawer"], targets: workspace),
            row("window.toggleDockLeft", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockLeft") + "\u{E002}" + String(localized: "action.window.toggleDockLeft", defaultValue: "Toggle Left Dock", table: "LayoutActions", bundle: .module)),
                .window, "sidebar.left", cli: "window toggle-dock-left", keywords: ["window", "dock", "workspace", "left", "show", "hide", "frame"], targets: [.window]),
            row("window.toggleDockRight", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockRight") + "\u{E002}" + String(localized: "action.window.toggleDockRight", defaultValue: "Toggle Right Dock", table: "LayoutActions", bundle: .module)),
                .window, "sidebar.right", cli: "window toggle-dock-right", keywords: ["window", "dock", "workspace", "right", "show", "hide", "frame"], targets: [.window]),
            row("window.toggleDockTop", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockTop") + "\u{E002}" + String(localized: "action.window.toggleDockTop", defaultValue: "Toggle Top Dock", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.tophalf.inset.filled", cli: "window toggle-dock-top", keywords: ["window", "dock", "workspace", "top", "show", "hide", "frame"], targets: [.window]),
            row("window.toggleDockBottom", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockBottom") + "\u{E002}" + String(localized: "action.window.toggleDockBottom", defaultValue: "Toggle Bottom Dock", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.bottomhalf.inset.filled", cli: "window toggle-dock-bottom", keywords: ["window", "dock", "workspace", "bottom", "panel", "terminal", "show", "hide", "frame"], targets: [.window]),
            row("window.toggleDockOrientation", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.window.toggleDockOrientation") + "\u{E002}" + String(localized: "action.window.toggleDockOrientation", defaultValue: "Toggle Dock Corners", table: "LayoutActions", bundle: .module)),
                .window, "rectangle.3.group", cli: "window toggle-dock-orientation", keywords: ["window", "dock", "corners", "orientation", "row", "column", "frame"], targets: [.window]),
        ]
    }
}
