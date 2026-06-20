/// Rendering owner for terminal backdrop pixels.
public enum GhosttyTerminalBackdropRenderingMode: Equatable, Sendable {
    /// The AppKit window host paints the terminal backdrop.
    case windowHostBackdrop

    /// Ghostty's renderer paints the terminal background image.
    case ghosttyRendererOwnedBackgroundImage

    /// Whether the AppKit window host owns the backdrop pixels.
    public var usesWindowHostBackdrop: Bool {
        self == .windowHostBackdrop
    }
}
