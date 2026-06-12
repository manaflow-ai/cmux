#if DEBUG
/// The outcome of `debug.command_palette.rename_input.selection`, preserving
/// the legacy body's three shapes: missing window (error), no focused field
/// editor (the zeroed `focused: false` payload), and an active field editor's
/// selection.
public enum ControlDebugRenameInputSelectionResolution: Sendable, Equatable {
    /// No window with the requested id exists (legacy `not_found`).
    case windowNotFound
    /// The window's first responder is not a field editor (legacy default
    /// payload: `focused: false`, zero selection).
    case inactive
    /// The field editor is focused; carries its selection range and text
    /// length (unclamped, as read from the editor).
    case active(location: Int, length: Int, textLength: Int)
}
#endif
