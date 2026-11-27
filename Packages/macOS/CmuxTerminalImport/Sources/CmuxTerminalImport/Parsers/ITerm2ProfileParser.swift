import Foundation

/// Reads the default profile from iTerm2's preferences (`com.googlecode.iterm2`).
///
/// Profiles live in `New Bookmarks`; the default one is named by
/// `Default Bookmark Guid`. Colors are dictionaries of float components with a
/// `Color Space` key; fonts are `"PostScriptName size"` strings.
public struct ITerm2ProfileParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Errors for preferences that hold no usable profile.
    public enum ParseError: Error, Equatable, Sendable {
        /// The preferences have no `New Bookmarks` profiles.
        case noProfiles
    }

    /// Parses the default profile out of the preferences domain.
    ///
    /// - Parameter preferences: The `com.googlecode.iterm2` domain as a dictionary.
    /// - Returns: The profile's settings.
    /// - Throws: ``ParseError/noProfiles`` when there is no profile.
    public func parse(preferences: [String: Any]) throws -> ImportedTerminalSettings {
        guard let profiles = preferences["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else {
            throw ParseError.noProfiles
        }
        let defaultGUID = preferences["Default Bookmark Guid"] as? String
        let profile = profiles.first { ($0["Guid"] as? String) == defaultGUID } ?? profiles[0]
        return parse(profile: profile)
    }

    /// Parses one profile dictionary.
    ///
    /// - Parameter profile: A single entry of `New Bookmarks`.
    /// - Returns: The profile's settings.
    public func parse(profile: [String: Any]) -> ImportedTerminalSettings {
        var settings = ImportedTerminalSettings(source: .iTerm2, profileName: profile["Name"] as? String)

        if let font = profile["Normal Font"] as? String {
            let parts = font.split(separator: " ")
            if parts.count >= 2, let size = ConfigValue.decimal(String(parts[parts.count - 1])) {
                settings.fontName = parts.dropLast().joined(separator: " ")
                settings.fontSize = size
            } else {
                settings.fontName = font
            }
            settings.fontNameIsPostScript = true
        }
        if (profile["Use Non-ASCII Font"] as? Bool) == true, let other = profile["Non Ascii Font"] as? String {
            settings.unmapped.append("Separate non-ASCII font (\(other)) is not imported.")
        }

        if (profile["Use Separate Colors for Light and Dark Mode"] as? Bool) == true {
            settings.colors = colorScheme(in: profile, suffix: " (Dark)")
            settings.lightColors = colorScheme(in: profile, suffix: " (Light)")
        } else {
            settings.colors = colorScheme(in: profile, suffix: "")
        }

        switch Self.int(profile["Cursor Type"]) {
        case 0: settings.cursorShape = .underline
        case 1: settings.cursorShape = .bar
        case 2: settings.cursorShape = .block
        default: break
        }
        if let blink = profile["Blinking Cursor"] as? Bool {
            settings.cursorBlink = blink
        }

        let left = Self.int(profile["Option Key Sends"])
        let right = Self.int(profile["Right Option Key Sends"])
        if left != nil || right != nil {
            // 0 = Normal, 1 = Meta, 2 = Esc+. Ghostty's Alt sends Esc+, so both non-normal modes map to Alt.
            settings.optionAsAlt = .init(left: (left ?? 0) != 0, right: (right ?? 0) != 0)
        }

        if let side = Self.double(profile["Side Margins"]) {
            settings.paddingLeft = side
            settings.paddingRight = side
        }
        if let vertical = Self.double(profile["Top/Bottom Margins"]) {
            settings.paddingTop = vertical
            settings.paddingBottom = vertical
        }

        if let transparency = Self.double(profile["Transparency"]) {
            settings.backgroundOpacity = 1 - transparency
        }
        if let blur = profile["Blur"] as? Bool {
            settings.backgroundBlur = blur ? ConfigValue.int(Self.double(profile["Blur Radius"]) ?? 2) : 0
        }

        if (profile["Unlimited Scrollback"] as? Bool) == true {
            settings.unlimitedScrollback = true
        } else if let lines = Self.int(profile["Scrollback Lines"]) {
            settings.scrollbackLines = lines
        }

        if let image = profile["Background Image Location"] as? String, !image.isEmpty {
            settings.unmapped.append("Background image (\(image)) is not imported.")
        }
        if (profile["Use Bold Font"] as? Bool) == false {
            settings.unmapped.append("\"Use bold font\" off is not imported.")
        }
        if let spacing = Self.double(profile["Vertical Spacing"]), spacing != 1 {
            settings.unmapped.append("Line spacing \(spacing) is not imported (see Ghostty's adjust-cell-height).")
        }
        return settings
    }

    private func colorScheme(in profile: [String: Any], suffix: String) -> TerminalColorScheme {
        var scheme = TerminalColorScheme()
        for index in 0..<16 {
            if let color = color(profile["Ansi \(index) Color\(suffix)"]) {
                scheme.palette[index] = color
            }
        }
        scheme.foreground = color(profile["Foreground Color\(suffix)"])
        scheme.background = color(profile["Background Color\(suffix)"])
        scheme.cursor = color(profile["Cursor Color\(suffix)"])
        scheme.cursorText = color(profile["Cursor Text Color\(suffix)"])
        scheme.selectionBackground = color(profile["Selection Color\(suffix)"])
        scheme.selectionForeground = color(profile["Selected Text Color\(suffix)"])
        return scheme
    }

    private func color(_ value: Any?) -> TerminalColor? {
        guard let dict = value as? [String: Any],
              let red = Self.double(dict["Red Component"]),
              let green = Self.double(dict["Green Component"]),
              let blue = Self.double(dict["Blue Component"]) else {
            return nil
        }
        let space: TerminalColor.ComponentSpace
        switch dict["Color Space"] as? String {
        case "sRGB": space = .sRGB
        case "P3": space = .displayP3
        case "Device": space = .deviceRGB
        default: space = .genericRGB
        }
        return TerminalColor(red: red, green: green, blue: blue, space: space)
    }

    /// A finite number from a plist value; NaN, infinity and non-numeric text read as absent.
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String { return ConfigValue.decimal(string) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        double(value).flatMap(ConfigValue.int)
    }
}
