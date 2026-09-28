/// Resolves ``ANSIArtColor`` values to concrete colors.
///
/// Indexes 0...15 use the terminal theme's colors when supplied in
/// `overrides` and standard xterm colors otherwise; 16...255 use the xterm
/// color cube and gray ramp unless overridden.
///
/// ```swift
/// let palette = ANSIArtPalette(
///     foreground: ANSIArtRGB(229, 229, 229),
///     background: ANSIArtRGB(0, 0, 0),
///     overrides: [1: ANSIArtRGB(204, 102, 102)]
/// )
/// ```
public struct ANSIArtPalette: Hashable, Sendable {
    /// xterm's default colors for indexes 0...15.
    public static let xtermBaseColors: [ANSIArtRGB] = [
        ANSIArtRGB(0, 0, 0), ANSIArtRGB(205, 0, 0), ANSIArtRGB(0, 205, 0), ANSIArtRGB(205, 205, 0),
        ANSIArtRGB(0, 0, 238), ANSIArtRGB(205, 0, 205), ANSIArtRGB(0, 205, 205), ANSIArtRGB(229, 229, 229),
        ANSIArtRGB(127, 127, 127), ANSIArtRGB(255, 0, 0), ANSIArtRGB(0, 255, 0), ANSIArtRGB(255, 255, 0),
        ANSIArtRGB(92, 92, 255), ANSIArtRGB(255, 0, 255), ANSIArtRGB(0, 255, 255), ANSIArtRGB(255, 255, 255),
    ]

    private static let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

    /// The color of text with no foreground set.
    public var foreground: ANSIArtRGB
    /// The color behind text with no background set. Only used for inverse text.
    public var background: ANSIArtRGB
    /// Theme colors keyed by palette index, taking precedence over the defaults.
    public var overrides: [Int: ANSIArtRGB]

    /// Creates a palette.
    ///
    /// - Parameters:
    ///   - foreground: The default foreground.
    ///   - background: The default background.
    ///   - overrides: Theme colors by palette index, usually the terminal's
    ///     `palette` entries. Defaults to none, which gives xterm's colors.
    public init(foreground: ANSIArtRGB, background: ANSIArtRGB, overrides: [Int: ANSIArtRGB] = [:]) {
        self.foreground = foreground
        self.background = background
        self.overrides = overrides
    }

    /// The color at a palette index; an index outside 0...255 reads as the
    /// default foreground.
    ///
    /// - Parameter index: The palette index.
    /// - Returns: The resolved color.
    public func rgb(forIndex index: Int) -> ANSIArtRGB {
        if let override = overrides[index] { return override }
        switch index {
        case 0...15:
            return Self.xtermBaseColors[index]
        case 16...231:
            let cube = index - 16
            return ANSIArtRGB(
                Self.cubeLevels[cube / 36],
                Self.cubeLevels[(cube / 6) % 6],
                Self.cubeLevels[cube % 6]
            )
        case 232...255:
            let level = UInt8(8 + (index - 232) * 10)
            return ANSIArtRGB(level, level, level)
        default:
            return foreground
        }
    }

    /// The concrete color for a parsed color.
    ///
    /// - Parameter color: The parsed color.
    /// - Returns: The resolved color.
    public func rgb(for color: ANSIArtColor) -> ANSIArtRGB {
        switch color {
        case .indexed(let index): rgb(forIndex: index)
        case .rgb(let rgb): rgb
        }
    }

    /// The colors to draw a style with, after inverse is applied.
    ///
    /// - Parameter style: The run's style.
    /// - Returns: The text color, and the cell background or `nil` when the
    ///   pane background should show through.
    public func resolvedColors(for style: ANSIArtStyle) -> (foreground: ANSIArtRGB, background: ANSIArtRGB?) {
        let foreground = style.foreground.map(rgb(for:)) ?? foreground
        let background = style.background.map(rgb(for:))
        guard style.isInverse else { return (foreground, background) }
        return (background ?? self.background, foreground)
    }
}
