/// The interaction that ended one visible command-palette lifecycle.
public enum CommandPaletteInteractionDismissal: Sendable, Equatable {
    /// A process-local pointer event occurred outside the palette panel.
    case pointer(CommandPalettePointerEvent)

    /// The palette's host window stopped being the key window.
    case windowResignedKey
}
