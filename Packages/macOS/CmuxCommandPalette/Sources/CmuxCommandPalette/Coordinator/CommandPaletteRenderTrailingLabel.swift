/// Trailing accessory shown on a command-palette result row.
///
/// A row either carries a keyboard ``CommandPaletteRenderTrailingLabelStyle/shortcut``
/// hint or a ``CommandPaletteRenderTrailingLabelStyle/kind`` label; the style
/// drives how the paired UI renders the `text`.
public struct CommandPaletteRenderTrailingLabel: Equatable, Sendable {
    /// The text rendered in the trailing position of the row.
    public let text: String
    /// Whether `text` is a keyboard-shortcut hint or a command-kind label.
    public let style: CommandPaletteRenderTrailingLabelStyle

    /// Creates a trailing label with the given `text` and `style`.
    public init(text: String, style: CommandPaletteRenderTrailingLabelStyle) {
        self.text = text
        self.style = style
    }
}
