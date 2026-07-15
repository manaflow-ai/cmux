extension MobileTerminalRenderGridFrame {
    public struct Style: Codable, Equatable, Sendable {
        public static let `default` = Style(id: 0)

        /// The terminal color source retained by a render-grid style.
        ///
        /// Keeping default and palette colors semantic lets a mirrored terminal
        /// respond to later theme changes instead of baking the producer's
        /// current resolved RGB value into every cell.
        public enum ColorSource: String, Codable, Equatable, Sendable {
            /// The terminal's current default foreground or background.
            case defaultColor = "default"
            /// An indexed terminal palette color.
            case palette
            /// A literal RGB color that must not change with the theme.
            case rgb
        }

        public var id: Int
        public var foreground: String?
        public var background: String?
        /// Semantic source for ``foreground``; `nil` denotes a legacy RGB-only frame.
        public var foregroundSource: ColorSource?
        /// Palette index when ``foregroundSource`` is ``ColorSource/palette``.
        public var foregroundPaletteIndex: Int?
        /// Semantic source for ``background``; `nil` denotes a legacy RGB-only frame.
        public var backgroundSource: ColorSource?
        /// Palette index when ``backgroundSource`` is ``ColorSource/palette``.
        public var backgroundPaletteIndex: Int?
        public var bold: Bool
        public var faint: Bool
        public var italic: Bool
        public var underline: Bool
        public var blink: Bool
        public var inverse: Bool
        public var invisible: Bool
        public var strikethrough: Bool
        public var overline: Bool

        public init(
            id: Int,
            foreground: String? = nil,
            background: String? = nil,
            foregroundSource: ColorSource? = nil,
            foregroundPaletteIndex: Int? = nil,
            backgroundSource: ColorSource? = nil,
            backgroundPaletteIndex: Int? = nil,
            bold: Bool = false,
            faint: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            blink: Bool = false,
            inverse: Bool = false,
            invisible: Bool = false,
            strikethrough: Bool = false,
            overline: Bool = false
        ) {
            self.id = id
            self.foreground = foreground
            self.background = background
            self.foregroundSource = foregroundSource
            self.foregroundPaletteIndex = foregroundPaletteIndex
            self.backgroundSource = backgroundSource
            self.backgroundPaletteIndex = backgroundPaletteIndex
            self.bold = bold
            self.faint = faint
            self.italic = italic
            self.underline = underline
            self.blink = blink
            self.inverse = inverse
            self.invisible = invisible
            self.strikethrough = strikethrough
            self.overline = overline
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(Int.self, forKey: .id)
            self.foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
            self.background = try container.decodeIfPresent(String.self, forKey: .background)
            self.foregroundSource = try container.decodeIfPresent(ColorSource.self, forKey: .foregroundSource)
            self.foregroundPaletteIndex = try container.decodeIfPresent(Int.self, forKey: .foregroundPaletteIndex)
            self.backgroundSource = try container.decodeIfPresent(ColorSource.self, forKey: .backgroundSource)
            self.backgroundPaletteIndex = try container.decodeIfPresent(Int.self, forKey: .backgroundPaletteIndex)
            self.bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            self.faint = try container.decodeIfPresent(Bool.self, forKey: .faint) ?? false
            self.italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            self.underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            self.blink = try container.decodeIfPresent(Bool.self, forKey: .blink) ?? false
            self.inverse = try container.decodeIfPresent(Bool.self, forKey: .inverse) ?? false
            self.invisible = try container.decodeIfPresent(Bool.self, forKey: .invisible) ?? false
            self.strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
            self.overline = try container.decodeIfPresent(Bool.self, forKey: .overline) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case id
            case foreground
            case background
            case foregroundSource = "foreground_source"
            case foregroundPaletteIndex = "foreground_palette_index"
            case backgroundSource = "background_source"
            case backgroundPaletteIndex = "background_palette_index"
            case bold
            case faint
            case italic
            case underline
            case blink
            case inverse
            case invisible
            case strikethrough
            case overline
        }
    }
}
