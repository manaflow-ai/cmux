public import CmuxNextDesign
public import Foundation

/// One theme file (`appearance.themeFile`, `~/.config/cmux/themes/<name>.json`) read as a look: a
/// partial overlay of the look settings, applied over cmux-next.json and under managed values. The
/// file is JSONC in cmux-next.json's own shape, nested (`{"appearance": {"accent": "blue"}}`) or
/// dotted at the top (`{"appearance.accent": "blue"}`), so a block copies between the two. Each value
/// passes the same schema check as `cmux settings set`; a refused one is dropped with a diagnostic
/// naming the file and the key, and the others still apply.
///
/// Besides settings, a theme file may carry its own terminal colors, which become
/// `appearance.themeEdits` of the terminal theme it names:
/// - `"colors"`: `{"background": "#1a1b26", "foreground": "#c0caf5", "cursor", "selection", "accent",
///   "0"..."15"}`, or `"palette": [16 colors]`.
/// - `"ghostty"`: a Ghostty theme block (a string or a list of lines: `background = #1a1b26`,
///   `palette = 4=#7aa2f7`), read as Ghostty theme files are (`ThemeFileColors`).
///
/// Contrast is guarded: a foreground under 4.5:1 on the file's background is replaced by the app
/// theme contract's text color (`AppTheme.derive`), so neither the terminal nor the chrome paints it
/// as written, and a `.correctedValue` diagnostic at `appearance.themeFile` says so in Settings.
public nonisolated struct ThemeFileOverlay: Sendable, Equatable {
    /// The theme file's name (`appearance.themeFile`).
    public let name: String
    /// Whether the file was found and read.
    public let isLoaded: Bool
    /// Each value the file sets, by key path, in a stable order.
    public let values: [(path: [String], value: JSONValue)]
    /// Refused values, a missing or unreadable file, and contrast corrections.
    public let diagnostics: [SettingsDiagnostic]
    /// The color tokens raised for contrast (`foreground`), empty when none were.
    public let corrected: [String]

    /// Keys a theme file reads that are not settings.
    static let reservedKeys: Set<String> = ["name", "description", "$schema", "colors", "ghostty"]
    /// Look keys that are no part of a look: the theme file itself, the star list and its rotation,
    /// per-machine and per-display maps, and the saved custom densities.
    static let excludedKeys: Set<String> = [
        ThemeFileSetting.path.joined(separator: "."), "appearance.favoriteThemes", "appearance.rotateFavoriteThemes",
        "appearance.machineColors", "appearance.displayBackgrounds", "appearance.displayBackgroundRotations",
        "appearance.customDensities",
    ]
    static let lookPrefixes = ["appearance.", "ui.animation", "ui.calm", "ui.paneAnimations", "ui.reducedBackgrounds",
                               "browser.omnibar.glass", "app.uiScale"]

    /// Whether a theme file may set `descriptor`: a look setting an agent may set too.
    public static func isLook(_ descriptor: SettingDescriptor) -> Bool {
        let id = descriptor.id
        return SettingsSchema.agentSettableKeys.contains(id) && !excludedKeys.contains(id)
            && lookPrefixes.contains { id.hasPrefix($0) }
    }

    /// Reads `name`'s file: its text, or nil when there is none. File I/O.
    public static func source(named name: String, configDirectory: URL) -> Result<String, any Error>? {
        let url = ThemeFileSetting.url(named: name, configDirectory: configDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Result {
            let data = try Data(contentsOf: url)
            guard data.count <= ThemeFileSetting.maximumBytes else { throw TooLarge() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct TooLarge: Error, CustomStringConvertible {
        var description: String { "larger than \(ThemeFileSetting.maximumBytes / 1024) KB" }
    }

    /// The file `name` read from `source` (nil: no file), over `base` (the settings it applies over:
    /// the terminal theme its colors edit and the edits it keeps).
    public init(name: String, source: Result<String, any Error>?, base: JSONValue) {
        self.name = name
        var reader = Reader(file: "\(ThemeFileSetting.folderName)/\(name).\(ThemeFileSetting.fileExtension)")
        isLoaded = reader.read(source, base: base)
        values = reader.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        diagnostics = reader.diagnostics
        corrected = reader.corrected
    }

    /// `root` with every value set, except keys a managed layer sets (dotted, as `managedKeys`).
    public func applied(to root: JSONValue, managed: Set<String> = []) -> JSONValue {
        values.reduce(root) { root, entry in
            let id = entry.path.joined(separator: ".")
            guard !managed.contains(where: { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) else { return root }
            return SettingsController.replacing(entry.path, with: entry.value, in: root)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.isLoaded == rhs.isLoaded && lhs.diagnostics == rhs.diagnostics && lhs.corrected == rhs.corrected
            && lhs.values.map(\.path) == rhs.values.map(\.path) && lhs.values.map(\.value) == rhs.values.map(\.value)
    }

    private struct Reader {
        let file: String
        var values: [(path: [String], value: JSONValue)] = []
        var diagnostics: [SettingsDiagnostic] = []
        var corrected: [String] = []

        /// Reads the file's text; false when there is none or it is not a JSON object.
        mutating func read(_ source: Result<String, any Error>?, base: JSONValue) -> Bool {
            guard let source else {
                refuse("", nil, "there is no file \(file)")
                return false
            }
            let parsed: JSONValue
            do {
                parsed = try JSONC.parse(try source.get())
            } catch {
                refuse("", nil, "\(file) could not be read (\(error))")
                return false
            }
            guard case .object(let members) = parsed else {
                refuse("", nil, "\(file) is not a JSON object")
                return false
            }
            for (key, value) in members.sorted(by: { $0.key < $1.key }) where !ThemeFileOverlay.reservedKeys.contains(key) {
                walk(value, path: CmuxConfigFile.keyPath(from: key))
            }
            readColors(members, base: base)
            return true
        }

        mutating func walk(_ value: JSONValue, path: [String]) {
            guard !path.isEmpty else { return }
            if let descriptor = SettingsSchema.descriptor(for: path) {
                take(descriptor, value)
            } else if case .object(let members) = value {
                for (key, member) in members.sorted(by: { $0.key < $1.key }) { walk(member, path: path + [key]) }
            } else {
                refuse(path.joined(separator: "."), value, "not a cmux setting")
            }
        }

        private mutating func take(_ descriptor: SettingDescriptor, _ value: JSONValue) {
            guard ThemeFileOverlay.isLook(descriptor) else {
                return refuse(descriptor.id, value, "a theme file sets only look settings")
            }
            guard descriptor.accepts(value) else { return refuse(descriptor.id, value, OmnibarSettingsSchema.expectation(descriptor)) }
            values.append((descriptor.path, value))
        }

        /// A refused entry of the file at its key (`colors.background` for a color). The file itself
        /// (missing, unreadable) is `path` "": cmux-next.json's `appearance.themeFile` names it.
        private mutating func refuse(_ path: String, _ value: JSONValue?, _ message: String) {
            guard !path.isEmpty else {
                return diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: ThemeFileSetting.path.joined(separator: "."), message: message))
            }
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: message, file: file, value: value?.compactText))
        }

        /// `colors` and `ghostty` as `appearance.themeEdits` of the terminal theme the file (or `base`) names.
        private mutating func readColors(_ members: [String: JSONValue], base: JSONValue) {
            var colors: [String: String] = [:]
            if let ghostty = members["ghostty"] { readGhostty(ghostty, into: &colors) }
            if let value = members["colors"] { readColorMap(value, into: &colors) }
            guard !colors.isEmpty else { return }
            let themePath = AppThemeSetting().configPath
            let theme = values.first { $0.path == themePath }?.value.stringValue ?? base.value(at: themePath)?.stringValue
            guard let theme, let spec = ThemeSpec(theme) else {
                return refuse("colors", nil, "colors need appearance.theme: they edit that terminal theme")
            }
            guardContrast(&colors)
            let editsPath = ThemeEditsSetting().configPath
            var edits = values.first { $0.path == editsPath }?.value.objectValue ?? base.value(at: editsPath)?.objectValue ?? [:]
            for name in Set([spec.light, spec.dark]) {
                for (token, color) in colors { edits[ThemeEditsSetting.key(theme: name, token: token)] = .string(color) }
            }
            values.removeAll { $0.path == editsPath }
            values.append((editsPath, .object(edits)))
        }

        private mutating func readColorMap(_ value: JSONValue, into colors: inout [String: String]) {
            guard case .object(let entries) = value else { return refuse("colors", value, "expected an object") }
            for (token, entry) in entries.sorted(by: { $0.key < $1.key }) {
                if token == "palette" {
                    guard let list = entry.arrayValue, list.count <= 16 else {
                        refuse("colors.palette", entry, "expected a list of up to 16 \"#RRGGBB\" colors")
                        continue
                    }
                    for (index, item) in list.enumerated() { set(String(index), item, into: &colors) }
                } else if ThemeEdits.tokens.contains(token) {
                    set(token, entry, into: &colors)
                } else {
                    refuse("colors.\(token)", entry, "unknown color; expected background, foreground, cursor, selection, accent, 0 to 15 or palette")
                }
            }
        }

        private mutating func set(_ token: String, _ value: JSONValue, into colors: inout [String: String]) {
            guard let text = value.stringValue, ThemeEdits.isColor(text) else {
                return refuse("colors.\(token)", value, "expected \"#RRGGBB\"")
            }
            colors[token] = text.lowercased()
        }

        private mutating func readGhostty(_ value: JSONValue, into colors: inout [String: String]) {
            let text = value.stringValue ?? value.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
            guard let text, let theme = ThemeFileColors(name: file, themeFile: text) else {
                return refuse("ghostty", value, "expected Ghostty theme lines with a background and a foreground")
            }
            colors["background"] = AppTheme.hex(theme.background)
            colors["foreground"] = AppTheme.hex(theme.foreground)
            for (index, color) in theme.palette.enumerated() { if let color { colors[String(index)] = AppTheme.hex(color) } }
            if let color = theme.cursorColor { colors["cursor"] = AppTheme.hex(color) }
            if let color = theme.selectionBackground { colors["selection"] = AppTheme.hex(color) }
            if let color = theme.accent { colors["accent"] = AppTheme.hex(color) }
        }

        /// A foreground under 4.5:1 on the background takes the app theme's text color for them.
        private mutating func guardContrast(_ colors: inout [String: String]) {
            guard let background = colors["background"].flatMap(ThemeRGB.init(cssHex:)),
                  let foreground = colors["foreground"].flatMap(ThemeRGB.init(cssHex:)),
                  foreground.contrast(with: background) < AppTheme.textMinimum else { return }
            let palette = (0..<16).map { colors[String($0)].flatMap(ThemeRGB.init(cssHex:)) }
            let fixed = AppTheme.hex(AppTheme.derive(background: background, foreground: foreground, palette: palette)[.text])
            let ratio = (foreground.contrast(with: background) * 10).rounded() / 10
            diagnostics.append(SettingsDiagnostic(
                kind: .correctedValue, path: ThemeFileSetting.path.joined(separator: "."),
                message: "\(file): the foreground \(colors["foreground"] ?? "") is \(ratio):1 on its background, so cmux shows \(fixed) (4.5:1 or more)",
                file: file, value: colors["foreground"].map { JSONValue.string($0).compactText }))
            colors["foreground"] = fixed
            corrected.append("foreground")
        }
    }
}
