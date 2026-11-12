/// The visual and input settings read from another terminal, before mapping to Ghostty.
///
/// Parsers fill in what the source defines and leave the rest `nil`. Anything a
/// parser saw but cannot express here goes in ``unmapped`` so the report can
/// say what was left behind.
public struct ImportedTerminalSettings: Equatable, Sendable {
    /// The cursor shape.
    public enum CursorShape: String, Equatable, Sendable {
        /// A filled block.
        case block
        /// A vertical bar (iTerm2 "vertical bar", Kitty "beam").
        case bar
        /// An underline.
        case underline
        /// An outlined block.
        case hollowBlock = "block_hollow"
    }

    /// Which Option keys act as Alt/Meta.
    public enum OptionAsAlt: String, Equatable, Sendable {
        /// Both Option keys.
        case both = "true"
        /// Neither Option key; Option composes characters.
        case neither = "false"
        /// Only the left Option key.
        case left
        /// Only the right Option key.
        case right

        /// Combines per-side flags into one value.
        public init(left: Bool, right: Bool) {
            switch (left, right) {
            case (true, true): self = .both
            case (true, false): self = .left
            case (false, true): self = .right
            case (false, false): self = .neither
            }
        }
    }

    /// Where the settings came from.
    public var source: TerminalImportSource
    /// The profile or file name within the source, for the report.
    public var profileName: String?
    /// The font name as the source stores it.
    public var fontName: String?
    /// Whether ``fontName`` is a PostScript name that should be resolved to a family.
    public var fontNameIsPostScript = false
    /// The font size in points.
    public var fontSize: Double?
    /// Colors used for every appearance, or for dark appearance when ``lightColors`` is set.
    public var colors = TerminalColorScheme()
    /// Colors for light appearance when the source keeps separate light and dark colors.
    public var lightColors: TerminalColorScheme?
    /// The cursor shape.
    public var cursorShape: CursorShape?
    /// Whether the cursor blinks.
    public var cursorBlink: Bool?
    /// Which Option keys act as Alt/Meta.
    public var optionAsAlt: OptionAsAlt?
    /// Left padding in points.
    public var paddingLeft: Double?
    /// Right padding in points.
    public var paddingRight: Double?
    /// Top padding in points.
    public var paddingTop: Double?
    /// Bottom padding in points.
    public var paddingBottom: Double?
    /// Background opacity from 0 (clear) to 1 (opaque).
    public var backgroundOpacity: Double?
    /// Background blur radius in Ghostty's units (0 means off).
    public var backgroundBlur: Int?
    /// Scrollback length in lines.
    public var scrollbackLines: Int?
    /// Whether the source keeps unlimited scrollback.
    public var unlimitedScrollback = false
    /// Settings the source defines that cmux does not import, one human-readable line each.
    public var unmapped: [String] = []

    /// Creates empty settings for a source.
    ///
    /// - Parameters:
    ///   - source: The terminal the settings are read from.
    ///   - profileName: The profile or file name, when the source has one.
    public init(source: TerminalImportSource, profileName: String? = nil) {
        self.source = source
        self.profileName = profileName
    }
}
