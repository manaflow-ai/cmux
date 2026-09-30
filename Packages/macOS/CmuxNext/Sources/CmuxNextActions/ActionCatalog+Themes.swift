// Room, workspace and terminal themes (plans/cmux-next/data-model.md 6).
// Titles live in ThemeActions.xcstrings.

nonisolated extension ActionCatalog {
    static func themeActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "room.setTheme",
                title: String(localized: "action.room.setTheme", defaultValue: "Set Room Theme…", table: "ThemeActions", bundle: .module),
                keywords: ["room", "profile", "theme", "colors", "ghostty", "appearance"], category: .workspace, symbol: "paintbrush",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.ghosttyThemeChoice], targets: [.profile],
                cliName: "room set-theme"
            ),
            ActionDescriptor(
                id: "room.clearTheme",
                title: String(localized: "action.room.clearTheme", defaultValue: "Reset Room Theme", table: "ThemeActions", bundle: .module),
                keywords: ["room", "profile", "theme", "reset", "ghostty"], category: .workspace, symbol: "paintbrush.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.profile], cliName: "room clear-theme"
            ),
            ActionDescriptor(
                id: "workspace.setTheme",
                title: String(localized: "action.workspace.setTheme", defaultValue: "Set Workspace Theme…", table: "ThemeActions", bundle: .module),
                keywords: ["workspace", "theme", "colors", "ghostty", "appearance"], category: .workspace, symbol: "paintbrush",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.ghosttyThemeChoice], targets: [.workspace],
                cliName: "workspace set-theme"
            ),
            ActionDescriptor(
                id: "workspace.clearTheme",
                title: String(localized: "action.workspace.clearTheme", defaultValue: "Reset Workspace Theme", table: "ThemeActions", bundle: .module),
                keywords: ["workspace", "theme", "reset", "ghostty"], category: .workspace, symbol: "paintbrush.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace clear-theme"
            ),
            ActionDescriptor(
                id: "terminal.setTheme",
                title: String(localized: "action.terminal.setTheme", defaultValue: "Set Terminal Theme…", table: "ThemeActions", bundle: .module),
                keywords: ["terminal", "tab", "theme", "colors", "ghostty", "palette"], category: .terminal, symbol: "paintbrush",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.ghosttyThemeChoice], targets: [.tab],
                cliName: "terminal set-theme"
            ),
            ActionDescriptor(
                id: "terminal.clearTheme",
                title: String(localized: "action.terminal.clearTheme", defaultValue: "Reset Terminal Theme", table: "ThemeActions", bundle: .module),
                keywords: ["terminal", "tab", "theme", "reset", "ghostty"], category: .terminal, symbol: "paintbrush.slash",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.tab], cliName: "terminal clear-theme"
            ),
        ]
    }
}

nonisolated extension CatalogArgument {
    /// Ghostty's built-in themes offered by onboarding, plus the Ghostty
    /// config (`config`, which resets). Theme names are product names and
    /// are not translated.
    static var ghosttyThemeChoice: ActionArgument {
        let config = ActionEnumCase(value: themeConfigValue,
                                    title: String(localized: "argument.value.theme.config", defaultValue: "Use Ghostty Config", table: "ThemeActions", bundle: .module))
        return ActionArgument(name: "theme", title: String(localized: "argument.theme", defaultValue: "Theme", table: "ThemeActions", bundle: .module),
                              kind: .enumeration([config] + curatedThemes.map { ActionEnumCase(value: $0, title: $0) }))
    }

    /// The `theme` value that means "the Ghostty config" (no own theme).
    static let themeConfigValue = "config"

    /// Same list and order as onboarding's theme step
    /// (`ThemeCatalog.curated` in CmuxNextDesign; a test keeps them equal).
    static let curatedThemes = [
        "Catppuccin Mocha", "TokyoNight", "Rose Pine", "Gruvbox Dark", "Nord", "Vesper",
        "Catppuccin Latte", "Rose Pine Dawn", "GitHub Light Default",
    ]
}

extension ActionArgument {
    /// The `theme` argument value that resets to the Ghostty config.
    public static let themeConfigValue = CatalogArgument.themeConfigValue
    /// Theme names the theme actions accept, in picker order.
    public static let curatedThemes = CatalogArgument.curatedThemes
}
