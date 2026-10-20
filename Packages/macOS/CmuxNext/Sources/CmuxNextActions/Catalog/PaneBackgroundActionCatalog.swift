// A pane's own background and marker tint (plans/cmux-next/pane-backgrounds-DESIGN.md): the
// pane's right-click Appearance folder, the palette, `cmux pane set-background|set-tint|
// clear-background`, and the MCP tools generated from these rows. One handler path
// (`PaneBackgroundHandlers`).

nonisolated enum PaneBackgroundActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "pane.setBackground",
                title: text("action.pane.setBackground", "Set Pane Background…"),
                keywords: ["pane", "background", "wallpaper", "art", "painting", "backdrop", "image", "split"],
                category: .pane, symbol: "photo", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.paneBackgroundChoice], targets: [.pane], cliName: "pane set-background",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.pane, .identity, 104, .choices, folder: .appearance),
                ])
            ),
            ActionDescriptor(
                id: "pane.setTint",
                title: text("action.pane.setTint", "Set Pane Tint…"),
                keywords: ["pane", "tint", "color", "colour", "marker", "agent", "prod", "background"],
                category: .pane, symbol: "paintpalette", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.paneTintChoice], targets: [.pane], cliName: "pane set-tint",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.pane, .identity, 105, .choices, folder: .appearance),
                ])
            ),
            ActionDescriptor(
                id: "pane.clearBackground",
                title: text("action.pane.clearBackground", "Reset Pane Background"),
                keywords: ["pane", "background", "tint", "reset", "clear", "inherit"],
                category: .pane, symbol: "photo.badge.arrow.down", surfaces: [.palette, .contextMenu],
                targets: [.pane], cliName: "pane clear-background",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.pane, .identity, 106, folder: .appearance),
                ])
            ),
        ]
    }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "LayoutActions", bundle: .module)
    }
}

nonisolated extension CatalogArgument {
    /// The `background` value that clears a pane's own pick (it follows its workspace again).
    static let paneBackgroundInherit = "inherit"
    /// The `color` value that clears a pane's tint.
    static let paneTintNone = "none"

    /// A pane's own background: `inherit`, `none`, `daily`, `desktop`, a bundled painting id, or a
    /// `system:` / `file:` path (the values `appearance.background` takes). Menus offer the
    /// common ones; the CLI takes any.
    static var paneBackgroundChoice: ActionArgument {
        let t = PaneBackgroundActionCatalog.text
        let pinned = [
            ActionEnumCase(value: paneBackgroundInherit, title: t("argument.value.paneBackground.inherit", "Same as Workspace")),
            ActionEnumCase(value: "none", title: t("argument.value.paneBackground.none", "None")),
            ActionEnumCase(value: "daily", title: t("argument.value.paneBackground.daily", "Shuffle Daily")),
            ActionEnumCase(value: "desktop", title: t("argument.value.paneBackground.desktop", "Desktop Wallpaper")),
        ]
        return ActionArgument(name: "background", title: t("argument.paneBackground", "Background"), kind: .string,
                              suggestions: ActionSuggestions(source: ActionSuggestions.paneBackgrounds, pinned: pinned))
    }

    /// A pane's marker tint: `none`, a named color, or `#RRGGBB`.
    static var paneTintChoice: ActionArgument {
        let t = PaneBackgroundActionCatalog.text
        let pinned = [
            ActionEnumCase(value: paneTintNone, title: t("argument.value.paneTint.none", "None")),
            ActionEnumCase(value: "red", title: t("argument.value.paneTint.red", "Red")),
            ActionEnumCase(value: "orange", title: t("argument.value.paneTint.orange", "Orange")),
            ActionEnumCase(value: "yellow", title: t("argument.value.paneTint.yellow", "Yellow")),
            ActionEnumCase(value: "green", title: t("argument.value.paneTint.green", "Green")),
            ActionEnumCase(value: "teal", title: t("argument.value.paneTint.teal", "Teal")),
            ActionEnumCase(value: "blue", title: t("argument.value.paneTint.blue", "Blue")),
            ActionEnumCase(value: "purple", title: t("argument.value.paneTint.purple", "Purple")),
            ActionEnumCase(value: "pink", title: t("argument.value.paneTint.pink", "Pink")),
            ActionEnumCase(value: "gray", title: t("argument.value.paneTint.gray", "Gray")),
        ]
        return ActionArgument(name: "color", title: t("argument.paneTint", "Tint"), kind: .string,
                              suggestions: ActionSuggestions(source: ActionSuggestions.paneTints, pinned: pinned))
    }
}
