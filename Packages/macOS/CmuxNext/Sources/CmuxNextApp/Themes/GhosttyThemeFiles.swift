import CmuxNextDesign
import Foundation

/// Theme files in the user's Ghostty themes folder (cx-wqn5.1): Save as Ghostty Theme writes a theme
/// with the user's edits there, and Import Theme File copies one in, so every picker lists it once the
/// catalog reloads. A theme file is Ghostty config, so only color keys are written or copied: an
/// imported `command =` or `config-file =` never reaches Ghostty. Shipped themes are never shadowed
/// and a user theme is replaced only when asked. File I/O: call off the main thread.
nonisolated enum GhosttyThemeFiles {
    enum Refusal: Error, Equatable {
        /// Not one theme name Ghostty and the pickers accept as a file name.
        case invalidName
        /// A shipped theme has this name; a user file would hide it.
        case shippedName
        /// A user theme has this name and replacing it was not asked for.
        case exists
        /// The base theme has no file.
        case unknownBase
        /// The file has no color a theme sets (or is too large to be a theme).
        case notATheme
    }

    /// The keys a theme file may set: colors only.
    static let colorKeys: Set<String> = ["palette", "background", "foreground", "cursor-color", "cursor-text",
                                          "selection-background", "selection-foreground", "bold-color"]

    /// `$XDG_CONFIG_HOME/ghostty/themes`, else `~/.config/ghostty/themes` (where Ghostty looks).
    static func userFolder(home: URL, environment: [String: String]) -> URL {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        return configHome.appending(path: "ghostty").appending(path: "themes")
    }

    /// Whether `name` can be a theme file's name: one theme spec name exactly (no pair, no `#`, `=`,
    /// `"` or control characters), no `/`, no leading dot, no surrounding spaces, at most 255 bytes
    /// (the file-name limit).
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name == name.trimmingCharacters(in: .whitespaces),
              !name.hasPrefix("."), !name.contains("/"), let spec = ThemeSpec(name) else { return false }
        return spec.light == name && spec.dark == name
    }

    /// Writes `base`'s colors with `edits` (`ThemeEdits` tokens to `#rrggbb`) as the user theme `name`.
    @discardableResult
    static func save(name: String, base: String, edits: [String: String], resources: String?, home: URL,
                     environment: [String: String], replace: Bool) throws -> URL {
        // The base is a theme name too, never a path to some other file.
        guard isValidName(base) else { throw Refusal.unknownBase }
        let target = try destination(name, resources: resources, home: home, environment: environment, replace: replace)
        let user = userFolder(home: home, environment: environment)
        let shipped = resources.map { URL(fileURLWithPath: $0).appending(path: "themes") }
        guard let file = [user.appending(path: base), shipped?.appending(path: base)].compactMap(\.self)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let text = try? String(contentsOf: file, encoding: .utf8) else { throw Refusal.unknownBase }
        let themeEdits = ThemeEdits([base: edits])
        // The accent is no Ghostty color: a comment line Ghostty skips and cmux reads back.
        let edited = themeEdits.configLines(for: base) + (themeEdits.accent(for: base).map { [accentLine($0)] } ?? [])
        let lines = merge(colorLines(text), edited)
        try write(["# \(name): \(base) with edits, saved by cmux"] + lines, to: target)
        return target
    }

    /// Copies the theme file at `url` into the user folder, colors only; its name is the file's
    /// (without a `.conf` or `.theme` extension). Returns the name.
    static func importTheme(at url: URL, resources: String?, home: URL, environment: [String: String],
                            replace: Bool) throws -> String {
        let name = ["conf", "theme"].contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard let data = try? Data(contentsOf: url), data.count <= ThemeCatalog.maximumThemeFileBytes else {
            throw Refusal.notATheme
        }
        let lines = colorLines(String(decoding: data, as: UTF8.self))
        guard lines.contains(where: { !$0.hasPrefix("#") }) else { throw Refusal.notATheme }
        let target = try destination(name, resources: resources, home: home, environment: environment, replace: replace)
        try write(["# \(name): imported by cmux from \(url.lastPathComponent)"] + lines, to: target)
        return name
    }

    /// The user file for `name`, after the name, shipped and replace checks.
    private static func destination(_ name: String, resources: String?, home: URL, environment: [String: String],
                                    replace: Bool) throws -> URL {
        guard isValidName(name) else { throw Refusal.invalidName }
        if let resources, FileManager.default.fileExists(atPath: URL(fileURLWithPath: resources).appending(path: "themes").appending(path: name).path) {
            throw Refusal.shippedName
        }
        let target = userFolder(home: home, environment: environment).appending(path: name)
        if !replace, FileManager.default.fileExists(atPath: target.path) { throw Refusal.exists }
        return target
    }

    /// The color lines of a theme file as `key = value`, and its `# cmux-accent` line, in order;
    /// everything else is dropped.
    static func colorLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let accent = ThemeFileColors.accent(line) { return accentLine(AppTheme.hex(accent)) }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard colorKeys.contains(key), !value.isEmpty, !value.contains(where: \.isNewline) else { return nil }
            return "\(key) = \(value)"
        }
    }

    /// `# cmux-accent = #rrggbb`.
    private static func accentLine(_ color: String) -> String { "# \(ThemeFileColors.accentKey) = \(color)" }

    /// `base` with each of `edits` replacing the line it sets (a palette edit, that index's line);
    /// an edit the base does not set is added at the end.
    private static func merge(_ base: [String], _ edits: [String]) -> [String] {
        var lines = base
        for edit in edits {
            if let index = lines.firstIndex(where: { slot($0) == slot(edit) }) {
                lines[index] = edit
                lines.removeAll { $0 != edit && slot($0) == slot(edit) }
            } else {
                lines.append(edit)
            }
        }
        return lines
    }

    /// What a line sets: its key, and for `palette` its index (`palette 4`).
    private static func slot(_ line: String) -> String {
        let parts = line.split(separator: "=", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "palette", parts.count > 1 else { return parts.first ?? line }
        return "palette \(parts[1])"
    }

    private static func write(_ lines: [String], to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: target, options: .atomic)
    }
}
