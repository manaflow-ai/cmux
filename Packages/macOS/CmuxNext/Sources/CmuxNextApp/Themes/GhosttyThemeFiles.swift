import CmuxNextDesign
import CmuxNextDevices
import Foundation

/// Theme files in the user's Ghostty themes folder (cx-wqn5.1): Save as Ghostty Theme writes a theme
/// with the user's edits there, and Import Theme File copies one in, so every picker lists it once the
/// catalog reloads. A theme file is Ghostty config, so only color keys are written or copied: an
/// imported `command =` or `config-file =` never reaches Ghostty. Shipped themes are never shadowed
/// and a user theme is replaced only when asked. File I/O: call off the main thread.
nonisolated enum GhosttyThemeFiles {
    enum Refusal: String, Error, Equatable, Decodable {
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

    /// `$XDG_CONFIG_HOME/ghostty/themes`, else `~/.config/ghostty/themes` (where Ghostty looks).
    static func userFolder(home: URL, environment: [String: String]) -> URL {
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        return configHome.appending(path: "ghostty").appending(path: "themes")
    }

    /// Whether `name` can be a theme file's name: one theme spec name exactly (no pair, no `#`, `=`,
    /// `"` or control characters), no `/`, no leading dot, no surrounding spaces, at most 255 bytes
    /// (the file-name limit).
    static func isValidName(_ name: String) -> Bool {
        struct Answer: Decodable { var valid: Bool }
        return AppRules.ask("app_themes_file_name_valid", ["name": name], as: Answer.self)?.valid ?? false
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
        let request = SaveRequest(name: name, base: base, baseText: text, edits: themeEdits.configLines(for: base),
                                  accent: themeEdits.accent(for: base))
        try write(answer(AppRules.ask("app_themes_file_save", request, as: FileAnswer.self)).text, to: target)
        return target
    }

    /// Copies the theme file at `url` into the user folder, colors only; its name is the file's
    /// (without a `.conf` or `.theme` extension). Returns the name.
    static func importTheme(at url: URL, resources: String?, home: URL, environment: [String: String],
                            replace: Bool) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw Refusal.notATheme }
        let request = ImportRequest(fileName: url.lastPathComponent, text: String(decoding: data, as: UTF8.self),
                                    size: data.count)
        let imported = try answer(AppRules.ask("app_themes_file_import", request, as: FileAnswer.self))
        let target = try destination(imported.name, resources: resources, home: home, environment: environment,
                                     replace: replace)
        try write(imported.text, to: target)
        return imported.name
    }

    /// The user file for `name`, after the name, shipped and replace checks.
    private static func destination(_ name: String, resources: String?, home: URL, environment: [String: String],
                                    replace: Bool) throws -> URL {
        let target = userFolder(home: home, environment: environment).appending(path: name)
        let shipped = resources.map {
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appending(path: "themes").appending(path: name).path)
        } ?? false
        let request = DestinationRequest(name: name, shipped: shipped,
                                         exists: FileManager.default.fileExists(atPath: target.path), replace: replace)
        struct Answer: Decodable { var refusal: Refusal? }
        guard let verdict = AppRules.ask("app_themes_file_destination", request, as: Answer.self) else {
            throw Refusal.invalidName
        }
        if let refusal = verdict.refusal { throw refusal }
        return target
    }

    private struct SaveRequest: Encodable { var name, base, baseText: String; var edits: [String]; var accent: String? }
    private struct ImportRequest: Encodable { var fileName, text: String; var size: Int }
    private struct DestinationRequest: Encodable { var name: String; var shipped, exists, replace: Bool }
    /// A theme file's text (and an import's name), or why there is none.
    private struct FileAnswer: Decodable { var name, text: String?; var refusal: Refusal? }

    private static func answer(_ answer: FileAnswer?) throws -> (name: String, text: String) {
        if let refusal = answer?.refusal { throw refusal }
        guard let text = answer?.text else { throw Refusal.notATheme }
        return (answer?.name ?? "", text)
    }

    private static func write(_ text: String, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
    }
}
