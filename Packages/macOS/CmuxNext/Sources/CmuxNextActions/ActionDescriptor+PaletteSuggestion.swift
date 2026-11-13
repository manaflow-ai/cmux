/// The commands an empty palette suggests to a new user, in order (the
/// Suggested section after Recent; plans/cmux-next/palette-ranking.md 5.2).
/// Catalog data in Rust (cmux-action-catalog `palette.rs`): exported as `palette_suggested` in
/// action-surfaces.json.
extension ActionDescriptor {
    nonisolated static var paletteSuggestions: [ActionID] { RustActionCatalog.shared.paletteSuggestions }

    /// This action's place in the empty palette's Suggested section, or nil.
    nonisolated public var paletteSuggestionRank: Int? {
        Self.paletteSuggestions.firstIndex(of: id)
    }
}
