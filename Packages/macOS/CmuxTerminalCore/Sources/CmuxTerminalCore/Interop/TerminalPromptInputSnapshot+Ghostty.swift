public import GhosttyKit

extension TerminalPromptInputSnapshot {
    /// Reads the shell input under the cursor of a live Ghostty surface.
    ///
    /// Takes Ghostty's renderer lock once, so call it for selection gestures,
    /// not on every keystroke.
    ///
    /// - Parameter surface: A live runtime surface.
    /// - Returns: The snapshot, or `nil` when Ghostty reports no editable
    ///   prompt: the alternate screen, a running command, no shell
    ///   integration, or a line without a prompt before its input.
    public static func read(from surface: ghostty_surface_t) -> TerminalPromptInputSnapshot? {
        var input = ghostty_surface_prompt_input_s()
        guard ghostty_surface_prompt_input(surface, &input) else { return nil }
        let selection: Range<Int>? = input.has_selection && input.selection_end > input.selection_start
            ? Int(input.selection_start)..<Int(input.selection_end)
            : nil
        return TerminalPromptInputSnapshot(
            length: Int(input.length),
            caret: Int(input.caret),
            selection: selection,
            selectionOutsideInput: selection == nil && ghostty_surface_has_selection(surface)
        )
    }
}
