import Foundation

/// One sRGB color from a Ghostty theme file.
public struct GhosttyThemeRGB: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#rrggbb`, `rrggbb`, `#rgb`, or `rgb`. Named X11 colors return `nil`.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 3 || digits.count == 6,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else {
            return nil
        }
        if digits.count == 3 {
            // Each nibble doubles: #abc is #aabbcc.
            self.init(
                red: UInt8((value >> 8) & 0xF) * 0x11,
                green: UInt8((value >> 4) & 0xF) * 0x11,
                blue: UInt8(value & 0xF) * 0x11
            )
        } else {
            self.init(
                red: UInt8((value >> 16) & 0xFF),
                green: UInt8((value >> 8) & 0xFF),
                blue: UInt8(value & 0xFF)
            )
        }
    }

    /// Perceptual brightness in 0...1, matching `NSColor.luminance`.
    public var luminance: Double {
        (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255
    }
}

/// The colors a Ghostty theme file sets: background, foreground, cursor and
/// the 16 ANSI palette entries. Keys the file leaves out stay `nil`.
public struct GhosttyThemeColors: Equatable, Sendable {
    public static let ansiPaletteCount = 16

    public var background: GhosttyThemeRGB?
    public var foreground: GhosttyThemeRGB?
    public var cursor: GhosttyThemeRGB?
    /// ANSI colors 0 through 15.
    public var palette: [GhosttyThemeRGB?]

    public init(
        background: GhosttyThemeRGB? = nil,
        foreground: GhosttyThemeRGB? = nil,
        cursor: GhosttyThemeRGB? = nil,
        palette: [GhosttyThemeRGB?] = Array(repeating: nil, count: ansiPaletteCount)
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.palette = palette
    }

    /// Parses the `key = value` lines of a Ghostty theme file. Later lines win,
    /// as they do when Ghostty loads the file; unknown keys are ignored.
    public init(parsing contents: String) {
        self.init()
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "background":
                background = GhosttyThemeRGB(hex: value) ?? background
            case "foreground":
                foreground = GhosttyThemeRGB(hex: value) ?? foreground
            case "cursor-color":
                cursor = GhosttyThemeRGB(hex: value) ?? cursor
            case "palette":
                // `palette = N=#rrggbb`
                guard let split = value.firstIndex(of: "="),
                      let index = Int(value[..<split].trimmingCharacters(in: .whitespaces)),
                      palette.indices.contains(index),
                      let color = GhosttyThemeRGB(hex: String(value[value.index(after: split)...])) else {
                    continue
                }
                palette[index] = color
            default:
                continue
            }
        }
    }

    /// Whether the background reads as dark; `nil` when the file sets none.
    public var isDark: Bool? {
        background.map { $0.luminance < 0.5 }
    }
}
