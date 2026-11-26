public import Foundation

/// Reads Alacritty's `alacritty.toml`, or the legacy `alacritty.yml`, plus the files it imports.
public struct AlacrittyConfigParser: Sendable {
    private let reader: any TerminalConfigFileReading
    private let homeDirectory: URL

    /// Creates a parser.
    ///
    /// - Parameters:
    ///   - reader: Reads the config and its imports.
    ///   - homeDirectory: Expands `~` in import paths.
    public init(reader: any TerminalConfigFileReading, homeDirectory: URL) {
        self.reader = reader
        self.homeDirectory = homeDirectory
    }

    /// Parses the config at `url`; a `.yml`/`.yaml` extension selects the YAML reader.
    ///
    /// - Parameter url: The main config file.
    /// - Returns: The settings, or `nil` when the file cannot be read.
    public func parse(url: URL) -> ImportedTerminalSettings? {
        guard let values = load(url, depth: 0) else { return nil }
        return settings(from: values, profileName: url.lastPathComponent)
    }

    private func load(_ url: URL, depth: Int) -> [String: ConfigValue]? {
        guard depth < 5, let text = reader.contents(of: url) else { return nil }
        let isYAML = ["yml", "yaml"].contains(url.pathExtension.lowercased())
        let own = isYAML ? MiniYAMLParser().parse(text) : MiniTOMLParser().parse(text)
        var merged: [String: ConfigValue] = [:]
        let imports = own["general.import"] ?? own["import"]
        if case .list(let paths)? = imports {
            let resolver = IncludePathResolver(homeDirectory: homeDirectory)
            for path in paths.compactMap(\.string) {
                if let imported = load(resolver.resolve(path, relativeTo: url), depth: depth + 1) {
                    merged.merge(imported) { _, new in new }
                }
            }
        }
        merged.merge(own) { _, new in new }
        return merged
    }

    func settings(from values: [String: ConfigValue], profileName: String?) -> ImportedTerminalSettings {
        var settings = ImportedTerminalSettings(source: .alacritty, profileName: profileName)
        func color(_ key: String) -> TerminalColor? {
            values[key]?.string.flatMap { TerminalColor(hex: $0) }
        }

        settings.fontName = values["font.normal.family"]?.string
        settings.fontSize = values["font.size"]?.number

        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (index, name) in names.enumerated() {
            if let normal = color("colors.normal.\(name)") { settings.colors.palette[index] = normal }
            if let bright = color("colors.bright.\(name)") { settings.colors.palette[index + 8] = bright }
        }
        settings.colors.foreground = color("colors.primary.foreground")
        settings.colors.background = color("colors.primary.background")
        settings.colors.cursor = color("colors.cursor.cursor")
        settings.colors.cursorText = color("colors.cursor.text")
        settings.colors.selectionBackground = color("colors.selection.background")
        settings.colors.selectionForeground = color("colors.selection.text")

        let shape = values["cursor.style.shape"]?.string ?? values["cursor.style"]?.string
        switch shape?.lowercased() {
        case "block": settings.cursorShape = .block
        case "beam": settings.cursorShape = .bar
        case "underline": settings.cursorShape = .underline
        case "hidden":
            settings.unmapped.append("Hidden cursor is not imported.")
        default: break
        }
        switch values["cursor.style.blinking"]?.string?.lowercased() {
        case "on", "always": settings.cursorBlink = true
        case "off", "never": settings.cursorBlink = false
        default: break
        }

        switch values["window.option_as_alt"]?.string?.lowercased() {
        case "onlyleft": settings.optionAsAlt = .left
        case "onlyright": settings.optionAsAlt = .right
        case "both": settings.optionAsAlt = .both
        case "none": settings.optionAsAlt = .neither
        default: break
        }

        if let x = values["window.padding.x"]?.number {
            settings.paddingLeft = x
            settings.paddingRight = x
        }
        if let y = values["window.padding.y"]?.number {
            settings.paddingTop = y
            settings.paddingBottom = y
        }
        settings.backgroundOpacity = values["window.opacity"]?.number ?? values["background_opacity"]?.number
        if let blur = values["window.blur"]?.bool {
            settings.backgroundBlur = blur ? 20 : 0
        }
        if let history = values["scrolling.history"]?.number {
            settings.scrollbackLines = ConfigValue.int(history)
        }

        if values["font.offset.y"] != nil || values["font.offset.x"] != nil {
            settings.unmapped.append("font.offset is not imported (see Ghostty's adjust-cell-height/width).")
        }
        if values["window.decorations"] != nil {
            settings.unmapped.append("window.decorations is not imported.")
        }
        if values.keys.contains(where: { $0.hasPrefix("colors.dim.") }) {
            settings.unmapped.append("Dim colors are not imported.")
        }
        return settings
    }
}
