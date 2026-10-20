#if DEBUG
/// Which command-palette notification a debug command posts. Each case maps to
/// one app-side `Notification.Name` the palette UI observes.
public enum ControlDebugCommandPaletteEvent: Sendable, Equatable {
    /// `debug.command_palette.toggle` (`commandPaletteToggleRequested`).
    case toggle
    /// `debug.command_palette.rename_tab.open`
    /// (`commandPaletteRenameTabRequested`).
    case renameTabOpen
    /// `debug.command_palette.rename_input.interact`
    /// (`commandPaletteRenameInputInteractionRequested`).
    case renameInputInteraction
    /// `debug.command_palette.rename_input.delete_backward`
    /// (`commandPaletteRenameInputDeleteBackwardRequested`).
    case renameInputDeleteBackward
}
#endif
