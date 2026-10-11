/// Colors of the shared-sizing chrome the surface draws: the grid border,
/// the hatch outside the grid, and the size chip.
///
/// Lines use the system separator, the gray of the terminal chrome's other
/// lines, resolved in the appearance the terminal chrome uses for the theme
/// (``usesDarkSeparator(onBackground:)``). The hatch is that color at
/// reduced opacity over the terminal background, with no fill of its own.
/// Only the chip text keeps a contrast floor, because it is text.
public struct TerminalSizingChromePalette: Equatable, Sendable {
    public typealias RGB = TerminalSizingPalette.RGB

    /// Opacity of the hatch lines relative to the separator color.
    public static let hatchOpacity = 0.6

    /// The terminal background the chrome sits on.
    public let background: RGB
    /// Grid border and chip outline: the separator as drawn over
    /// ``background``.
    public let line: RGB
    /// Hatch lines outside the grid: ``line`` at ``hatchOpacity``.
    public let hatch: RGB
    /// The chip's fill: the terminal background.
    public var chipFill: RGB { background }
    /// Chip text, at least 4.5:1 on ``chipFill``.
    public let text: RGB

    /// - Parameters:
    ///   - background: The terminal background.
    ///   - foreground: The terminal foreground; chip text mixes toward it.
    ///   - line: The separator color, already composited over `background`.
    public init(background: RGB, foreground: RGB, line: RGB) {
        self.background = background
        self.line = line
        hatch = background.mixed(toward: line, by: Self.hatchOpacity)
        text = TerminalSizingPalette(background: background, foreground: foreground).text
    }

    /// Whether the terminal chrome on `background` draws in the dark
    /// appearance: white text reads better on it than black. Same rule as
    /// the terminal screen's color scheme.
    public static func usesDarkSeparator(onBackground background: RGB) -> Bool {
        let luminance = background.relativeLuminance
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return blackContrast < whiteContrast
    }
}
