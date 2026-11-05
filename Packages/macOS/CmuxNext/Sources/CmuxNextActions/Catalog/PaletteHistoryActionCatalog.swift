// The palette's search memory (plans/cmux-next/palette-ranking.md 5.2): Clear Palette Search History
// forgets every use and learned pick of Cmd-P and Cmd-Shift-P. The palette, the Settings button and
// `cmux settings clear-palette-history` run this one action. Turning the memory off is the
// `palette.searchHistory` setting.

nonisolated enum PaletteHistoryActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.clearSearchHistory",
                title: String(localized: "action.palette.clearSearchHistory", defaultValue: "Clear Palette Search History",
                              table: "SettingsActions", bundle: .module),
                keywords: ["palette", "search", "history", "memory", "recent", "frecency", "ranking", "forget", "reset"],
                category: .settings, symbol: "clock.arrow.circlepath", surfaces: [.palette],
                cliName: "settings clear-palette-history",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }
}
