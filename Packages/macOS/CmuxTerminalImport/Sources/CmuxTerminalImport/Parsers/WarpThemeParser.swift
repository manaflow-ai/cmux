import Foundation

/// Reads a Warp custom theme (`~/.warp/themes/*.yaml`).
///
/// Warp keeps fonts and other settings in its own app state, so only theme colors are imported.
public struct WarpThemeParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses a Warp theme file.
    ///
    /// - Parameters:
    ///   - source: The YAML text.
    ///   - profileName: The theme file name, for the report.
    /// - Returns: The theme's colors.
    public func parse(source: String, profileName: String?) -> ImportedTerminalSettings {
        let values = MiniYAMLParser().parse(source)
        var settings = ImportedTerminalSettings(source: .warp, profileName: profileName)
        func color(_ key: String) -> TerminalColor? {
            values[key]?.string.flatMap { TerminalColor(hex: $0) }
        }
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (index, name) in names.enumerated() {
            if let normal = color("terminal_colors.normal.\(name)") { settings.colors.palette[index] = normal }
            if let bright = color("terminal_colors.bright.\(name)") { settings.colors.palette[index + 8] = bright }
        }
        settings.colors.foreground = color("foreground")
        settings.colors.background = color("background")
        settings.colors.cursor = color("cursor") ?? color("accent")
        if values.keys.contains(where: { $0.hasPrefix("background.") }) {
            settings.unmapped.append("Gradient background is not imported.")
        }
        if values["background_image.path"] != nil {
            settings.unmapped.append("Background image is not imported.")
        }
        settings.unmapped.append("Warp keeps fonts and other settings in its own app state; only theme colors are imported.")
        return settings
    }
}
