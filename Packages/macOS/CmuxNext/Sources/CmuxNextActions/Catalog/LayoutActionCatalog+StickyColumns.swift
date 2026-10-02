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
            row("column.toggleStickyOverlay", String(localized: "action.column.toggleStickyOverlay", defaultValue: "Toggle Sticky Overlay", table: "LayoutActions", bundle: .module),
                .pane, "square.on.square", cli: "column toggle-sticky-overlay", keywords: ["column", "sticky", "overlay", "float", "dock"], targets: targets),
            row("layout.toggleStripScrollbar", String(localized: "action.layout.toggleStripScrollbar", defaultValue: "Toggle Column Scroll Bar", table: "LayoutActions", bundle: .module),
                .settings, "scroll", cli: "settings toggle-column-scrollbar", keywords: ["scrollbar", "column", "strip", "minimap"], targets: []),
        ]
    }
}
