/// The SGR attributes that apply to a run of ANSI art text.
///
/// The default value is the terminal's unstyled state: default colors, normal
/// weight. `nil` colors mean "the palette's default foreground/background".
public struct ANSIArtStyle: Hashable, Sendable {
    /// The foreground color, or `nil` for the default foreground.
    public var foreground: ANSIArtColor?
    /// The background color, or `nil` for the default (transparent) background.
    public var background: ANSIArtColor?
    /// SGR `1`.
    public var isBold = false
    /// SGR `2`.
    public var isDim = false
    /// SGR `7`: foreground and background swap when resolved.
    public var isInverse = false

    /// Creates the unstyled default.
    public init() {}
}
