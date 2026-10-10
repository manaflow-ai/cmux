/// The commands an empty palette suggests to a new user, in order (the
/// Suggested section after Recent; plans/cmux-next/palette-ranking.md 5.2).
/// Catalog data: exported as `palette_suggested` in action-surfaces.json.
extension ActionDescriptor {
    nonisolated static let paletteSuggestions: [ActionID] = [
        "newTab.default", "splitRight", "openBrowser", "palette.newAgentChat", "newTab", "openSettings",
    ]

    /// This action's place in the empty palette's Suggested section, or nil.
    nonisolated public var paletteSuggestionRank: Int? {
        Self.paletteSuggestions.firstIndex(of: id)
    }
}
