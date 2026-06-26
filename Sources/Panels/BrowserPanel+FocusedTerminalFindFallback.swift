import CmuxTerminal

/// Conforms the app-target ``BrowserPanel`` to the find-fallback seam
/// ``FocusedTerminalFindFallback`` used by
/// ``FocusedTerminalCommandCoordinator`` when no terminal panel is focused.
///
/// `startFind()`, `findNext()`, `findPrevious()`, and `hideFind()` are satisfied
/// directly by `BrowserPanel`'s existing methods; only `isSearchVisible` maps to
/// the panel's `searchState`.
extension BrowserPanel: FocusedTerminalFindFallback {
    var isSearchVisible: Bool {
        searchState != nil
    }
}
