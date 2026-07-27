/// Native terminal implementation used for newly-created desktop surfaces.
public enum TerminalRuntimeBackend: Sendable {
    /// The existing libghostty terminal and Metal renderer.
    case ghostty

    /// Alacritty's terminal core, PTY loop, and OpenGL renderer.
    case alacritty
}
