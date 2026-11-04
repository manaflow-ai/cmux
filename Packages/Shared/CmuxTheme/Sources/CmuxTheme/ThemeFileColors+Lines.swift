import Foundation

extension ThemeFileColors {
    /// The keys a theme file may set: colors only.
    public static let colorKeys: Set<String> = ["palette", "background", "foreground", "cursor-color", "cursor-text",
                                                "selection-background", "selection-foreground", "bold-color"]

    /// The color lines of a theme file as `key = value`, and its `# cmux-accent` line, in order;
    /// everything else is dropped.
    public static func colorLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let accent = accent(line) { return accentLine(AppTheme.hex(accent)) }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard colorKeys.contains(key), !value.isEmpty, !value.contains(where: \.isNewline) else { return nil }
            return "\(key) = \(value)"
        }
    }

    /// `# cmux-accent = #rrggbb`.
    public static func accentLine(_ color: String) -> String { "# \(accentKey) = \(color)" }

    /// The name an imported theme file gets: its file name without a theme or scheme extension.
    public static func importedName(_ url: URL) -> String {
        ["conf", "theme", "yaml", "yml"].contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}
