public import CmuxNextDesign
import Foundation

/// Parses a Ghostty theme file (`background = #1e1e2e`,
/// `palette = 0=#45475a`, `selection-background = ...`) into the colors the
/// chrome derives from. Unknown keys and comments are ignored; missing
/// palette entries fall back to Ghostty's defaults.
public nonisolated enum GhosttyThemeFile {
    public static func parse(_ text: String) -> ThemeInput? {
        var background: ThemeRGB?
        var foreground: ThemeRGB?
        var selectionBackground: ThemeRGB?
        var selectionForeground: ThemeRGB?
        var palette = ThemeInput.ghosttyDefault.palette
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = ThemeRGB(cssHex: value)
            case "foreground": foreground = ThemeRGB(cssHex: value)
            case "selection-background": selectionBackground = ThemeRGB(cssHex: value)
            case "selection-foreground": selectionForeground = ThemeRGB(cssHex: value)
            case "palette":
                guard let split = value.firstIndex(of: "="), let index = Int(value[..<split].trimmingCharacters(in: .whitespaces)),
                      (0..<16).contains(index), let color = ThemeRGB(cssHex: String(value[value.index(after: split)...])) else { continue }
                while palette.count <= index { palette.append(.black) }
                palette[index] = color
            default:
                continue
            }
        }
        guard let background, let foreground else { return nil }
        return ThemeInput(background: background, foreground: foreground, palette: palette,
                          selectionBackground: selectionBackground, selectionForeground: selectionForeground)
    }
}

/// A theme the welcome step offers: the user's own Ghostty theme (name nil)
/// or a theme shipped with Ghostty, by file name.
public nonisolated struct ThemeChoice: Sendable, Equatable, Identifiable {
    /// Ghostty theme name (`theme = <name>`); nil is "keep my Ghostty theme".
    public var name: String?
    public var input: ThemeInput

    public var id: String { name ?? "" }

    public init(name: String?, input: ThemeInput) {
        self.name = name
        self.input = input
    }

    /// Hand-picked Ghostty themes, dark first. Names are Ghostty file names.
    public static let curated = [
        "Catppuccin Mocha", "TokyoNight", "Rose Pine", "Gruvbox Dark", "Nord", "Vesper",
        "Catppuccin Latte", "Rose Pine Dawn", "GitHub Light Default",
    ]

    /// Loads the curated themes found in a Ghostty resources directory
    /// (`<dir>/themes/<name>`), in curated order. Reads files: call off-main.
    public static func loadCurated(resourcesDirectory: String?, names: [String] = curated) -> [ThemeChoice] {
        guard let resourcesDirectory else { return [] }
        let themes = URL(fileURLWithPath: resourcesDirectory, isDirectory: true).appending(path: "themes", directoryHint: .isDirectory)
        return names.compactMap { name in
            // concurrency-allow: nonisolated static; callers run it off the main thread
            guard let text = try? String(contentsOf: themes.appending(path: name), encoding: .utf8),
                  let input = GhosttyThemeFile.parse(text) else { return nil }
            return ThemeChoice(name: name, input: input)
        }
    }
}
