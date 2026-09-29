import Foundation

/// The terminal palettes an agent theme is exported from.
public enum AgentThemeAppearances: Equatable, Sendable {
    /// One palette used in both light and dark appearance.
    case single(TerminalPalette)
    /// Different palettes for light and dark appearance, as set by
    /// `theme = light:<name>,dark:<name>` in the Ghostty config.
    case pair(light: TerminalPalette, dark: TerminalPalette)
}
