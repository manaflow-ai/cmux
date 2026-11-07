import CmuxCommandPalette

/// Corpus source for the sidebar tab search: the Cmd-P switcher entries
/// (workspaces + surfaces, each with its focus action) and a cheap fingerprint
/// of that corpus.
///
/// Both closures are backed by `ContentView`'s shared switcher builders
/// (`commandPaletteSwitcherEntries(includeSurfaces:)` /
/// `commandPaletteSwitcherEntriesFingerprint(includeSurfaces:)`), so the
/// sidebar entrypoint never keeps a second copy of the switcher corpus logic.
/// The defaults are empty so previews and tests can construct the sidebar
/// without wiring it.
struct SidebarTabSearchSource {
    /// Returns the current switcher corpus with ready-made navigation actions.
    var entries: () -> [CommandPaletteCommand] = { [] }
    /// Returns a hash of the corpus (names and metadata, no fuzzy preparation).
    /// The search view compares it on every keystroke and rebuilds its session
    /// cache on a mismatch.
    var fingerprint: () -> Int = { 0 }
}
