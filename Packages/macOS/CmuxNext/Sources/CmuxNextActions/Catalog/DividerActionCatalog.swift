// A split's divider (its right-click menu, Leo 2026-11-07): Insert New puts a new pane of a kind at the divider,
// between the two sides it separates, taking its room from both (cmux-layout-reducer `divider_insert`); Hide
// Divider and Show Divider draw its line or not, kept on the split in the layout (`set-divider-visible`). Without a
// `split` (the palette, a script that names none) they act on the divider beside the focused pane. One handler
// path (`DividerActions`, CmuxNextDaemonService). Titles live in LayoutActions.xcstrings.

nonisolated enum DividerActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "divider.insertNew",
                title: text("action.divider.insertNew", "Insert New"),
                keywords: ["divider", "split", "insert", "new", "between", "pane", "terminal", "browser", "agent", "chat", "tab"],
                category: .pane, symbol: "rectangle.split.3x1", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.dividerInsertKind, CatalogArgument.dividerSplit],
                targets: [.workspace], cliName: "divider insert",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.divider, .create, 0, .choices),
                ])
            ),
            ActionDescriptor(
                id: "divider.hide",
                title: text("action.divider.hide", "Hide Divider"),
                keywords: ["divider", "split", "line", "hide", "invisible", "separator", "border"],
                category: .pane, symbol: "eye.slash", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.dividerSplit], targets: [.workspace], cliName: "divider hide",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.divider, .view, 0)])
            ),
            ActionDescriptor(
                id: "divider.show",
                title: text("action.divider.show", "Show Divider"),
                keywords: ["divider", "split", "line", "show", "visible", "separator", "border"],
                category: .pane, symbol: "eye", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.dividerSplit], targets: [.workspace], cliName: "divider show",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.divider, .view, 1)])
            ),
        ]
    }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "LayoutActions", bundle: .module)
    }
}

nonisolated extension CatalogArgument {
    /// The `kind` values of Insert New, in its submenu's order.
    static let dividerInsertKinds = ["terminal", "browser", "agentChat", "newTabPage"]

    /// What Insert New opens at the divider.
    static var dividerInsertKind: ActionArgument {
        let t = DividerActionCatalog.text
        return ActionArgument(name: "kind", title: t("argument.dividerInsertKind", "Kind"), kind: .enumeration([
            ActionEnumCase(value: "terminal", title: t("argument.value.dividerInsertKind.terminal", "Terminal")),
            ActionEnumCase(value: "browser", title: t("argument.value.dividerInsertKind.browser", "Browser")),
            ActionEnumCase(value: "agentChat", title: t("argument.value.dividerInsertKind.agentChat", "Agent Chat")),
            ActionEnumCase(value: "newTabPage", title: t("argument.value.dividerInsertKind.newTabPage", "New Tab Page")),
        ]))
    }

    /// The divider's split: its public id (`split_…`, as `cmux layout` lists it) or the daemon's handle. The menu
    /// passes the right-clicked one; without it, the divider beside the focused pane.
    static var dividerSplit: ActionArgument {
        ActionArgument(name: "split", title: DividerActionCatalog.text("argument.dividerSplit", "Divider"), kind: .string).optional
    }
}
