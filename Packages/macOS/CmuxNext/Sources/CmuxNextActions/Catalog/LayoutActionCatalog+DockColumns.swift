// Docked columns and the strip scrollbar (plans/cmux-next/dock-column.md).
// Titles live in LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func dockColumnActions() -> [ActionDescriptor] {
        let targets: [ActionTargetKind] = [.column, .pane]
        return [
            row("column.dock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.dock") + "\u{E002}" + String(localized: "action.column.dock", defaultValue: "Dock Column", table: "LayoutActions", bundle: .module)),
                .pane, "pin", cli: "column dock", keywords: ["column", "dock", "pin", "undock"], targets: targets,
                arguments: [CatalogArgument.edgeChoice.optional, CatalogArgument.dockModeChoice.optional],
                // Ctrl-Cmd-P ("pin"): free in the catalog and in macOS.
                defaultShortcut: Shortcut("p", modifiers: [.control, .command])),
            row("column.dockLeft", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.dockLeft") + "\u{E002}" + String(localized: "action.column.dockLeft", defaultValue: "Dock Column Left", table: "LayoutActions", bundle: .module)),
                .pane, "rectangle.lefthalf.inset.filled", cli: "column dock-left", keywords: ["column", "dock", "pin", "left"], targets: targets),
            row("column.dockRight", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.dockRight") + "\u{E002}" + String(localized: "action.column.dockRight", defaultValue: "Dock Column Right", table: "LayoutActions", bundle: .module)),
                .pane, "rectangle.righthalf.inset.filled", cli: "column dock-right", keywords: ["column", "dock", "pin", "right"], targets: targets),
            row("column.dockTop", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.dockTop") + "\u{E002}" + String(localized: "action.column.dockTop", defaultValue: "Dock Column Top", table: "LayoutActions", bundle: .module)),
                .pane, "rectangle.tophalf.inset.filled", cli: "column dock-top", keywords: ["column", "dock", "pin", "top"], targets: targets),
            row("column.dockBottom", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.dockBottom") + "\u{E002}" + String(localized: "action.column.dockBottom", defaultValue: "Dock Column Bottom", table: "LayoutActions", bundle: .module)),
                .pane, "rectangle.bottomhalf.inset.filled", cli: "column dock-bottom", keywords: ["column", "dock", "pin", "bottom"], targets: targets),
            row("column.float", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.float") + "\u{E002}" + String(localized: "action.column.float", defaultValue: "Float Column", table: "LayoutActions", bundle: .module)),
                .pane, "square.on.square", cli: "column float", keywords: ["column", "float", "floating", "overlay"], targets: targets),
            row("column.undock", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.column.undock") + "\u{E002}" + String(localized: "action.column.undock", defaultValue: "Undock Column", table: "LayoutActions", bundle: .module)),
                .pane, "pin.slash", cli: "column undock", keywords: ["column", "undock", "unpin", "scroll"], targets: targets),
            // A column of its own, pinned in the same daemon commit: the way
            // to pin a screen's only column (that column must keep scrolling).
            row("tab.moveToNewDockColumn", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.tab.moveToNewDockColumn") + "\u{E002}" + String(localized: "action.tab.moveToNewDockColumn", defaultValue: "Move Tab to New Dock Column", table: "LayoutActions", bundle: .module)),
                .tab, "pin", cli: "tab move-to-new-dock-column", keywords: ["tab", "column", "pin", "dock", "top", "bottom"],
                targets: [.tab], arguments: [CatalogArgument.edgeChoice.optional, CatalogArgument.dockModeChoice.optional]),
            row("layout.toggleStripScrollbar", ("\u{E000}LayoutActions\u{E001}" + String(describing: "action.layout.toggleStripScrollbar") + "\u{E002}" + String(localized: "action.layout.toggleStripScrollbar", defaultValue: "Toggle Column Scroll Bar", table: "LayoutActions", bundle: .module)),
                .settings, "scroll", cli: "settings toggle-column-scrollbar", keywords: ["scrollbar", "column", "strip", "visible range", "overview"], targets: []),
        ]
    }
}
