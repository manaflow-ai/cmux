public import Foundation

/// Reads Kitty's `kitty.conf`, following `include` lines (such as the
/// `current-theme.conf` that `kitten themes` writes).
public struct KittyConfigParser: Sendable {
    private let reader: any TerminalConfigFileReading
    private let homeDirectory: URL

    /// Creates a parser.
    ///
    /// - Parameters:
    ///   - reader: Reads the config and its includes.
    ///   - homeDirectory: Expands `~` in include paths.
    public init(reader: any TerminalConfigFileReading, homeDirectory: URL) {
        self.reader = reader
        self.homeDirectory = homeDirectory
    }

    /// Parses the config at `url`.
    ///
    /// - Parameter url: The main `kitty.conf`.
    /// - Returns: The settings, or `nil` when the file cannot be read.
    public func parse(url: URL) -> ImportedTerminalSettings? {
        var values: [String: String] = [:]
        var skipped: [String] = []
        guard load(url, depth: 0, into: &values, skipped: &skipped) else { return nil }
        var settings = settings(from: values, profileName: url.lastPathComponent)
        settings.unmapped.append(contentsOf: skipped)
        return settings
    }

    private func load(_ url: URL, depth: Int, into values: inout [String: String], skipped: inout [String]) -> Bool {
        guard depth < 5, let text = reader.contents(of: url) else { return false }
        let resolver = IncludePathResolver(homeDirectory: homeDirectory)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "include":
                if !load(resolver.resolve(value, relativeTo: url), depth: depth + 1, into: &values, skipped: &skipped) {
                    skipped.append("include \(value) could not be read.")
                }
            case "globinclude", "envinclude", "geninclude":
                skipped.append("\(key) \(value) is not followed.")
            default:
                values[key] = value
            }
        }
        return true
    }

    func settings(from values: [String: String], profileName: String?) -> ImportedTerminalSettings {
        var settings = ImportedTerminalSettings(source: .kitty, profileName: profileName)
        func color(_ key: String) -> TerminalColor? {
            values[key].flatMap { TerminalColor(hex: $0) }
        }

        if let family = values["font_family"].flatMap(Self.fontFamily) {
            settings.fontName = family
        }
        settings.fontSize = values["font_size"].flatMap { ConfigValue.decimal($0) }

        for index in 0..<16 {
            if let value = color("color\(index)") { settings.colors.palette[index] = value }
        }
        settings.colors.foreground = color("foreground")
        settings.colors.background = color("background")
        settings.colors.cursor = color("cursor")
        settings.colors.cursorText = color("cursor_text_color")
        settings.colors.selectionBackground = color("selection_background")
        settings.colors.selectionForeground = color("selection_foreground")

        switch values["cursor_shape"]?.lowercased() {
        case "block": settings.cursorShape = .block
        case "beam": settings.cursorShape = .bar
        case "underline": settings.cursorShape = .underline
        default: break
        }
        if let interval = values["cursor_blink_interval"].flatMap({ $0.split(separator: " ").first }).flatMap({ ConfigValue.decimal(String($0)) }) {
            settings.cursorBlink = interval != 0
        }

        switch values["macos_option_as_alt"]?.lowercased() {
        case "yes", "both": settings.optionAsAlt = .both
        case "left": settings.optionAsAlt = .left
        case "right": settings.optionAsAlt = .right
        case "no": settings.optionAsAlt = .neither
        default: break
        }

        if let padding = values["window_padding_width"] {
            let numbers = padding.split(separator: " ").compactMap { ConfigValue.decimal(String($0)) }
            // CSS order: all | vertical horizontal | top horizontal bottom | top right bottom left.
            switch numbers.count {
            case 1:
                (settings.paddingTop, settings.paddingRight, settings.paddingBottom, settings.paddingLeft) =
                    (numbers[0], numbers[0], numbers[0], numbers[0])
            case 2:
                (settings.paddingTop, settings.paddingRight, settings.paddingBottom, settings.paddingLeft) =
                    (numbers[0], numbers[1], numbers[0], numbers[1])
            case 3:
                (settings.paddingTop, settings.paddingRight, settings.paddingBottom, settings.paddingLeft) =
                    (numbers[0], numbers[1], numbers[2], numbers[1])
            case 4:
                (settings.paddingTop, settings.paddingRight, settings.paddingBottom, settings.paddingLeft) =
                    (numbers[0], numbers[1], numbers[2], numbers[3])
            default:
                break
            }
        }
        settings.backgroundOpacity = values["background_opacity"].flatMap { ConfigValue.decimal($0) }
        if let blur = values["background_blur"].flatMap({ ConfigValue.decimal($0) }) {
            settings.backgroundBlur = ConfigValue.int(blur)
        }
        if let lines = values["scrollback_lines"].flatMap({ ConfigValue.decimal($0) }) {
            if lines < 0 {
                settings.unlimitedScrollback = true
            } else {
                settings.scrollbackLines = ConfigValue.int(lines)
            }
        }

        for key in ["bold_font", "italic_font", "bold_italic_font"] where values[key].map({ $0 != "auto" }) == true {
            settings.unmapped.append("\(key) is not imported.")
        }
        if values["modify_font"] != nil {
            settings.unmapped.append("modify_font is not imported (see Ghostty's adjust-cell-height).")
        }
        if values["background_image"] != nil {
            settings.unmapped.append("background_image is not imported.")
        }
        return settings
    }

    /// The family from either `font_family Fira Code` or the newer `font_family family="Fira Code" ...`.
    static func fontFamily(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: "family=") {
            var rest = trimmed[range.upperBound...]
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest = rest.dropFirst()
                return rest.split(separator: quote, maxSplits: 1).first.map(String.init)
            }
            return rest.split(separator: " ").first.map(String.init)
        }
        guard !trimmed.isEmpty, trimmed != "auto", trimmed != "monospace" else { return nil }
        return trimmed
    }
}
