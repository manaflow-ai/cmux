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
            ActionDescriptor(
                id: "workspace.setTint",
                title: text("action.workspace.setTint", "Set Workspace Tint…"),
                keywords: ["workspace", "tint", "color", "colour", "marker", "prod", "project"],
                category: .workspace, symbol: "paintpalette", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.paneTintChoice], targets: [.workspace], cliName: "workspace set-tint",
                surfacePlan: ActionSurfacePlan(cli: .offered)
            ),
            ActionDescriptor(
                id: "tab.setTint",
                title: text("action.tab.setTint", "Set Tab Tint…"),
                keywords: ["tab", "tint", "color", "colour", "marker", "agent", "terminal"],
                category: .terminal, symbol: "paintpalette", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.paneTintChoice], targets: [.tab], cliName: "tab set-tint",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.tab, .identity, 207, .choices, folder: .options),
                ])
            ),
            // The one generic path every level and property shares (appearance-scopes-DESIGN.md);
            // menus offer its common values through the rows above.
            ActionDescriptor(
                id: "appearance.set",
                title: text("action.appearance.set", "Set Appearance…"),
                keywords: ["appearance", "theme", "background", "wallpaper", "tint", "opacity", "window", "workspace", "pane", "tab"],
                category: .settings, symbol: "paintbrush", surfaces: [.palette],
                arguments: [CatalogArgument.appearanceScope, CatalogArgument.appearanceProperty, CatalogArgument.appearanceValue],
                targets: [.tab, .pane, .workspace], cliName: "appearance set",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .familyMember)
            ),
            ActionDescriptor(
                id: "appearance.reset",
                title: text("action.appearance.reset", "Reset Appearance to Inherited"),
                keywords: ["appearance", "reset", "inherit", "inherited", "theme", "background", "tint"],
                category: .settings, symbol: "arrow.uturn.backward", surfaces: [.palette],
                arguments: [CatalogArgument.appearanceScope, CatalogArgument.appearanceProperty.optional],
                targets: [.tab, .pane, .workspace], cliName: "appearance reset",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .familyMember)
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
            ActionEnumCase(value: "daily", title: t("argument.value.paneBackground.shufflePaintings", "Shuffle Paintings")),
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

    /// Which level `appearance.set` and `appearance.reset` act on.
    static var appearanceScope: ActionArgument {
        let t = PaneBackgroundActionCatalog.text
        return ActionArgument(name: "scope", title: t("argument.appearanceScope", "Scope"), kind: .enumeration([
            ActionEnumCase(value: "window", title: t("argument.value.appearanceScope.window", "Window")),
            ActionEnumCase(value: "workspace", title: t("argument.value.appearanceScope.workspace", "Workspace")),
            ActionEnumCase(value: "pane", title: t("argument.value.appearanceScope.pane", "Pane")),
            ActionEnumCase(value: "tab", title: t("argument.value.appearanceScope.tab", "Tab")),
        ]))
    }

    /// Which property `appearance.set` and `appearance.reset` change; reset without one resets all.
    static var appearanceProperty: ActionArgument {
        let t = PaneBackgroundActionCatalog.text
        return ActionArgument(name: "property", title: t("argument.appearanceProperty", "Property"), kind: .enumeration([
            ActionEnumCase(value: "theme", title: t("argument.value.appearanceProperty.theme", "Theme")),
            ActionEnumCase(value: "background", title: t("argument.value.appearanceProperty.background", "Background")),
            ActionEnumCase(value: "tint", title: t("argument.value.appearanceProperty.tint", "Tint")),
            ActionEnumCase(value: "opacity", title: t("argument.value.appearanceProperty.opacity", "Opacity")),
        ]))
    }

    /// The value `appearance.set` gives the property (its own vocabulary).
    static var appearanceValue: ActionArgument {
        ActionArgument(name: "value", title: PaneBackgroundActionCatalog.text("argument.appearanceValue", "Value"), kind: .string)
    }
}
