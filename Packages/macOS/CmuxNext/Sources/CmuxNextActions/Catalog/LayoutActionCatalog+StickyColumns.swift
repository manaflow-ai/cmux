// Sticky columns and the strip scrollbar (plans/cmux-next/sticky-column.md).
// Titles live in LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func stickyColumnActions() -> [ActionDescriptor] {
        let targets: [ActionTargetKind] = [.column, .pane]
        return [
            row("column.dock", String(localized: "action.column.dock", defaultValue: "Dock Column", table: "LayoutActions", bundle: .module),
                .pane, "pin", cli: "column dock", keywords: ["column", "dock", "sticky", "pin", "undock"], targets: targets,
                arguments: [CatalogArgument.edgeChoice.optional, CatalogArgument.stickyModeChoice.optional],
                // Ctrl-Cmd-P ("pin"): free in the catalog and in macOS.
                defaultShortcut: Shortcut("p", modifiers: [.control, .command])),
            row("column.dockLeft", String(localized: "action.column.dockLeft", defaultValue: "Dock Column Left", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.lefthalf.inset.filled", cli: "column dock-left", keywords: ["column", "dock", "sticky", "pin", "left"], targets: targets),
            row("column.dockRight", String(localized: "action.column.dockRight", defaultValue: "Dock Column Right", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.righthalf.inset.filled", cli: "column dock-right", keywords: ["column", "dock", "sticky", "pin", "right"], targets: targets),
            row("column.dockTop", String(localized: "action.column.dockTop", defaultValue: "Dock Column Top", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.tophalf.inset.filled", cli: "column dock-top", keywords: ["column", "dock", "sticky", "pin", "top"], targets: targets),
            row("column.dockBottom", String(localized: "action.column.dockBottom", defaultValue: "Dock Column Bottom", table: "LayoutActions", bundle: .module),
                .pane, "rectangle.bottomhalf.inset.filled", cli: "column dock-bottom", keywords: ["column", "dock", "sticky", "pin", "bottom"], targets: targets),
            row("column.float", String(localized: "action.column.float", defaultValue: "Float Column", table: "LayoutActions", bundle: .module),
                .pane, "square.on.square", cli: "column float", keywords: ["column", "float", "floating", "overlay", "sticky"], targets: targets),
            row("column.undock", String(localized: "action.column.undock", defaultValue: "Undock Column", table: "LayoutActions", bundle: .module),
                .pane, "pin.slash", cli: "column undock", keywords: ["column", "undock", "unpin", "unstick", "scroll"], targets: targets),
            // A column of its own, pinned in the same daemon commit: the way
            // to pin a screen's only column (that column must keep scrolling).
            row("tab.moveToNewStickyColumn", String(localized: "action.tab.moveToNewStickyColumn", defaultValue: "Move Tab to New Sticky Column", table: "LayoutActions", bundle: .module),
                .tab, "pin", cli: "tab move-to-new-sticky-column", keywords: ["tab", "column", "sticky", "pin", "dock", "top", "bottom"],
                targets: [.tab], arguments: [CatalogArgument.edgeChoice.optional, CatalogArgument.stickyModeChoice.optional]),
            row("layout.toggleStripScrollbar", String(localized: "action.layout.toggleStripScrollbar", defaultValue: "Toggle Column Scroll Bar", table: "LayoutActions", bundle: .module),
                .settings, "scroll", cli: "settings toggle-column-scrollbar", keywords: ["scrollbar", "column", "strip", "minimap"], targets: []),
        ]
    }
}
