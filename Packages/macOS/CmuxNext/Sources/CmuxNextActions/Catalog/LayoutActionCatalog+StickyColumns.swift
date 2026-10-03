// Sticky columns and the strip scrollbar (plans/cmux-next/sticky-column.md).
// Titles live in LayoutActions.xcstrings.

nonisolated extension LayoutActionCatalog {
    static func stickyColumnActions() -> [ActionDescriptor] {
        let targets: [ActionTargetKind] = [.column, .pane]
        return [
            row("column.makeSticky", String(localized: "action.column.makeSticky", defaultValue: "Make Column Sticky", table: "LayoutActions", bundle: .module),
                .pane, "pin", cli: "column make-sticky", keywords: ["column", "sticky", "pin", "overlay", "dock"],
                targets: targets, arguments: [CatalogArgument.edgeChoice.optional, CatalogArgument.stickyModeChoice.optional]),
            row("column.makeStickyLeft", String(localized: "action.column.makeStickyLeft", defaultValue: "Make Column Sticky on Left", table: "LayoutActions", bundle: .module),
                .pane, "pin", cli: "column make-sticky-left", keywords: ["column", "sticky", "pin", "left"], targets: targets),
            row("column.unstick", String(localized: "action.column.unstick", defaultValue: "Unstick Column", table: "LayoutActions", bundle: .module),
                .pane, "pin.slash", cli: "column unstick", keywords: ["column", "sticky", "unpin", "scroll"], targets: targets),
            row("column.toggleStickyOverlay", String(localized: "action.column.toggleStickyOverlay", defaultValue: "Toggle Floating Sticky Column", table: "LayoutActions", bundle: .module),
                .pane, "square.on.square", cli: "column toggle-sticky-overlay", keywords: ["column", "sticky", "floating", "overlay", "float", "dock"], targets: targets),
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
