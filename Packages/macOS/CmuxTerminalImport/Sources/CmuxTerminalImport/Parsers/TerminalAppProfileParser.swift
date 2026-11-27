import Foundation

/// Reads the default profile from macOS Terminal's preferences (`com.apple.Terminal`).
///
/// Profiles live under `Window Settings`, keyed by name; the default is named by
/// `Default Window Settings`. Colors and the font are `NSKeyedArchiver` data.
public struct TerminalAppProfileParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Errors for preferences that hold no usable profile.
    public enum ParseError: Error, Equatable, Sendable {
        /// The default profile is one of Terminal's built-ins the user never changed,
        /// so its settings are not stored in the preferences.
        case builtInProfile(String)
    }

    private static let ansiKeys = [
        "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
        "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
        "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
        "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor",
    ]

    /// Parses the default profile out of the preferences domain.
    ///
    /// - Parameter preferences: The `com.apple.Terminal` domain as a dictionary.
    /// - Returns: The profile's settings.
    /// - Throws: ``ParseError/builtInProfile(_:)`` when the default profile is not stored.
    public func parse(preferences: [String: Any]) throws -> ImportedTerminalSettings {
        let name = preferences["Default Window Settings"] as? String ?? "Basic"
        let profiles = preferences["Window Settings"] as? [String: Any] ?? [:]
        guard let profile = profiles[name] as? [String: Any], profile.count > 3 else {
            throw ParseError.builtInProfile(name)
        }
        return parse(profile: profile, name: name)
    }

    /// Parses one profile dictionary.
    ///
    /// - Parameters:
    ///   - profile: One entry of `Window Settings`.
    ///   - name: The profile's name, for the report.
    /// - Returns: The profile's settings.
    public func parse(profile: [String: Any], name: String) -> ImportedTerminalSettings {
        let decoder = KeyedArchiveValueDecoder()
        var settings = ImportedTerminalSettings(source: .terminalApp, profileName: name)

        func color(_ key: String) -> KeyedArchiveValueDecoder.Color? {
            (profile[key] as? Data).flatMap { decoder.color(from: $0) }
        }

        if let data = profile["Font"] as? Data, let font = decoder.font(from: data) {
            settings.fontName = font.postScriptName
            settings.fontNameIsPostScript = true
            settings.fontSize = font.size
        }

        for (index, key) in Self.ansiKeys.enumerated() {
            if let value = color(key) {
                settings.colors.palette[index] = value.color
            }
        }
        settings.colors.foreground = color("TextColor")?.color
        settings.colors.cursor = color("CursorColor")?.color
        settings.colors.selectionBackground = color("SelectionColor")?.color
        if let background = color("BackgroundColor") {
            settings.colors.background = background.color
            settings.backgroundOpacity = background.alpha
        }

        switch ITerm2ProfileParser.int(profile["CursorType"]) {
        case 0: settings.cursorShape = .block
        case 1: settings.cursorShape = .underline
        case 2: settings.cursorShape = .bar
        default: break
        }
        if let blink = profile["CursorBlink"] as? Bool {
            settings.cursorBlink = blink
        }
        if let meta = profile["useOptionAsMetaKey"] as? Bool {
            settings.optionAsAlt = meta ? .both : .neither
        }
        if let blur = ITerm2ProfileParser.double(profile["BackgroundBlur"]) {
            // Terminal's blur slider runs 0 to 1; Ghostty's default blur is 20.
            settings.backgroundBlur = ConfigValue.int(blur * 20)
        }
        if (profile["ShouldLimitScrollback"] as? Bool) == true,
           let lines = ITerm2ProfileParser.int(profile["ScrollbackLines"]) {
            settings.scrollbackLines = lines
        }

        if profile["TextBoldColor"] != nil {
            settings.unmapped.append("Bold text color is not imported.")
        }
        if let spacing = ITerm2ProfileParser.double(profile["FontHeightSpacing"]), spacing != 1 {
            settings.unmapped.append("Line spacing \(spacing) is not imported (see Ghostty's adjust-cell-height).")
        }
        if profile["BackgroundImagePath"] != nil || profile["BackgroundImageBookmark"] != nil {
            settings.unmapped.append("Background image is not imported.")
        }
        return settings
    }
}
