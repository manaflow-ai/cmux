public import CMUXMobileCore

/// Agent GUI colors derived only from the resolved Ghostty terminal theme.
public struct AgentGUITheme: Hashable, Sendable {
    /// Terminal background.
    public let background: AgentGUIRGBColor
    /// Terminal foreground.
    public let foreground: AgentGUIRGBColor
    /// Foreground mixed 60/40 with the background.
    public let dimForeground: AgentGUIRGBColor
    /// Foreground mixed 40/60 with the background.
    public let faintForeground: AgentGUIRGBColor
    /// Foreground mixed 5/95 with the background.
    public let raisedBackground: AgentGUIRGBColor
    /// Foreground mixed 8/92 with the background.
    public let inputBackground: AgentGUIRGBColor
    /// Foreground mixed 12/88 with the background.
    public let hoverBackground: AgentGUIRGBColor
    /// Foreground mixed 15/85 with the background.
    public let border: AgentGUIRGBColor
    /// First qualifying cool ANSI color, or the terminal foreground.
    public let accent: AgentGUIRGBColor
    /// First available ANSI red color, or `nil` for a platform fail-open fallback.
    public let error: AgentGUIRGBColor?

    /// Derives the GUI palette from one terminal theme value.
    /// - Parameter terminalTheme: The Ghostty theme transported from the Mac.
    public init(terminalTheme: TerminalTheme) {
        let terminalTheme = terminalTheme.validatedOrDefault()
        let background = AgentGUIRGBColor(hex: terminalTheme.background)
            ?? AgentGUIRGBColor(hex: TerminalTheme.monokai.background)!
        let foreground = AgentGUIRGBColor(hex: terminalTheme.foreground)
            ?? AgentGUIRGBColor(hex: TerminalTheme.monokai.foreground)!
        self.background = background
        self.foreground = foreground
        dimForeground = foreground.mixed(with: background, ownWeight: 0.60)
        faintForeground = foreground.mixed(with: background, ownWeight: 0.40)
        raisedBackground = foreground.mixed(with: background, ownWeight: 0.05)
        inputBackground = foreground.mixed(with: background, ownWeight: 0.08)
        hoverBackground = foreground.mixed(with: background, ownWeight: 0.12)
        border = foreground.mixed(with: background, ownWeight: 0.15)
        accent = Self.accent(palette: terminalTheme.palette, fallback: foreground)
        error = Self.error(palette: terminalTheme.palette)
    }

    private static func accent(palette: [String], fallback: AgentGUIRGBColor) -> AgentGUIRGBColor {
        for index in [4, 12, 6, 14, 5, 13, 2, 10] where palette.indices.contains(index) {
            guard let candidate = AgentGUIRGBColor(hex: palette[index]) else {
                continue
            }
            let hsl = candidate.hueAndSaturation
            if hsl.saturation >= 0.22, hsl.hue >= 180, hsl.hue <= 290 {
                return candidate
            }
        }
        return fallback
    }

    private static func error(palette: [String]) -> AgentGUIRGBColor? {
        for index in [1, 9] where palette.indices.contains(index) {
            if let candidate = AgentGUIRGBColor(hex: palette[index]) {
                return candidate
            }
        }
        return nil
    }
}
