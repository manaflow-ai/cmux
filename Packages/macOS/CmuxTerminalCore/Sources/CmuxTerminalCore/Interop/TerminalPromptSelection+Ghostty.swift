public import GhosttyKit

extension TerminalPromptSelection {
    /// Selects this selection's caret stops on a live Ghostty surface.
    ///
    /// Never writes a clipboard, whatever `copy-on-select` says.
    ///
    /// - Parameter surface: A live runtime surface.
    /// - Returns: Whether Ghostty made the selection. It refuses when the
    ///   cursor is no longer in editable prompt input or the range falls
    ///   outside it.
    public func select(on surface: ghostty_surface_t) -> Bool {
        ghostty_surface_select_prompt_input(
            surface,
            UInt32(clamping: range.lowerBound),
            UInt32(clamping: range.upperBound)
        )
    }
}
