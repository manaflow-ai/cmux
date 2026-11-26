public import CmuxNextDesign
import CmuxNextCompat
public import Foundation

/// One theme file (`appearance.themeFile`, `~/.config/cmux-next/themes/<name>.json`) read as a look: a
/// partial overlay of the look settings, applied over cmux-next.json and under managed values. The
/// file is JSONC in cmux-next.json's own shape, nested (`{"appearance": {"accent": "blue"}}`) or
/// dotted at the top (`{"appearance.accent": "blue"}`), so a block copies between the two. Each value
/// passes the same schema check as `cmux settings set`; a refused one is dropped with a diagnostic
/// naming the file and the key, and the others still apply.
///
/// Besides settings, a theme file may carry its own terminal colors, which become
/// `appearance.themeEdits` of the terminal theme it names:
/// - `"colors"`: `{"background": "#1a1b26", "foreground": "#c0caf5", "cursor", "selection", "accent",
///   "0"..."15"}`, with `"palette": [16 colors]` inside it for the ANSI slots.
/// - `"ghostty"`: a Ghostty theme block (a string or a list of lines: `background = #1a1b26`,
///   `palette = 4=#7aa2f7`), read as Ghostty theme files are (`ThemeFileColors`).
///
/// A theme file may also carry its own density (`"density"`): the shape of every tab and sidebar row, the toolbar's
/// buttons and the sidebar's width. It starts from a built-in (`basedOn`) and sets the Density Playground's tokens
/// over it (``DensityTokenCatalog``); while the file applies, that density is the one in use, over
/// `appearance.density`:
/// `"density": {"basedOn": "compact", "tokens": {"tabCornerRadius": 2, "sidebarCornerRadius": 2, "sidebarWidth": 250}}`.
///
/// It may bring its own font files (`"fonts": ["file:/…/Sakura-Mono.otf"]`, a theme pack's faces): they
/// are registered for the app while the file applies (``ThemeFonts``), so `terminal.fontFamily` can name them.
///
/// A background picture may be relative (`"file:harbor.jpg"`, `"folder:walls"`) or start at `~`: it
/// resolves against the themes folder, so a theme and its pictures move together as one folder.
///
/// Contrast is guarded: in any theme the file colors, a foreground under 4.5:1 on its background is
/// replaced by the app theme contract's text color (`AppTheme.derive`), so neither the terminal nor
/// the chrome paints it as written, and a `.correctedValue` diagnostic at `appearance.themeFile` says
/// so in Settings.
public nonisolated struct ThemeFileOverlay: Sendable, Equatable {
    /// The theme file's name (`appearance.themeFile`).
    public let name: String
    /// Whether the file was found and read.
    public let isLoaded: Bool
    /// Whether the file is there but is no JSON object (a save mid-edit): the load keeps the last
    /// good text of the same file (`SettingsController`), as cmux-next.json keeps its last good load.
    public let isUnparsable: Bool
    /// Each value the file sets, by key path, in a stable order.
    public let values: [(path: [String], value: JSONValue)]
    /// Refused values, a missing or unreadable file, and contrast corrections.
    public internal(set) var diagnostics: [SettingsDiagnostic]
    /// The color tokens raised for contrast (`foreground`), empty when none were.
    public let corrected: [String]
    /// The file's own density (`"density"`), nil when it sets none.
    public let density: DensityTokens?
    /// The file's own font files (`"fonts"`, a theme pack's faces), registered while it applies
    /// (``ThemeFonts``).
    public let fontFiles: [URL]

    /// Whether a theme file may set `descriptor`: a look setting an agent may set too. Rust answers
    /// (`theme.is_look`, cmux-config's `theme_file::is_look`).
    public static func isLook(_ descriptor: SettingDescriptor) -> Bool {
        SettingsRust.answer("theme.is_look", .object(["key": .string(descriptor.id)]))["look"]?.boolValue ?? false
    }

    /// Reads `name`'s file, the user's or else the one cmux ships (`ThemeFileSetting.bundledFolder`): its
    /// text, or nil when there is none. File I/O.
    public static func source(named name: String, configDirectory: URL,
                              bundled: URL? = ThemeFileSetting.bundledFolder) -> Result<String, any Error>? {
        guard let url = ThemeFileSetting.readableURL(named: name, configDirectory: configDirectory, bundled: bundled) else { return nil }
        return Result {
            let data = try Data(blockingContentsOf: url)
            guard data.count <= ThemeFileSetting.maximumBytes else { throw TooLarge() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct TooLarge: Error, CustomStringConvertible {
        var description: String { "larger than \(ThemeFileSetting.maximumBytes / 1024) KB" }
    }

    /// The file `name` read from `source` (nil: no file), over `base` (the settings it applies over:
    /// the terminal theme its colors edit and the edits it keeps). A relative picture resolves against
    /// `folder`, the themes folder (nil leaves it relative, which the schema refuses).
    public init(name: String, source: Result<String, any Error>?, base: JSONValue, folder: URL? = nil) {
        self.name = name
        var request: [String: JSONValue] = ["name": .string(name), "base": base]
        if let folder { request["folder"] = .string(folder.path) }
        switch source {
        case .success(let text)?: request["text"] = .string(text)
        case .failure(let error)?: request["error"] = .string(JSONC.problem(error, in: nil))
        case nil: break
        }
        // Rust reads the settings, the colors and the contrast guard (`theme.read`); the density and
        // the font files are read here, as they need the density catalog and file URLs.
        let reply = SettingsRust.answer("theme.read", .object(request))
        var reader = Reader(file: "\(ThemeFileSetting.folderName)/\(name).\(ThemeFileSetting.fileExtension)", folder: folder)
        reader.values = (reply["values"]?.arrayValue ?? []).compactMap { entry in
            guard let path = entry["path"]?.arrayValue?.compactMap(\.stringValue), let value = entry["value"] else { return nil }
            return (path, value)
        }
        reader.diagnostics = (reply["diagnostics"]?.arrayValue ?? []).compactMap { entry in
            guard let kind = entry["kind"]?.stringValue.flatMap(SettingsDiagnostic.Kind.init(rawValue:)),
                  let message = entry["message"]?.stringValue else { return nil }
            return SettingsDiagnostic(kind: kind, path: entry["path"]?.stringValue ?? "", message: message,
                                      file: entry["file"]?.stringValue, value: entry["value"]?.stringValue)
        }
        isLoaded = reply["loaded"]?.boolValue ?? false
        isUnparsable = reply["unparsable"]?.boolValue ?? false
        corrected = reply["corrected"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if isLoaded {
            if let value = reply["density"] { reader.readDensity(value, named: reply["title"]?.stringValue, base: base) }
            if let value = reply["fonts"] { reader.readFonts(value) }
        }
        values = reader.values
        diagnostics = reader.diagnostics
        density = reader.density
        fontFiles = reader.fontFiles
    }

    /// `root` with every value set, except keys a managed layer sets (dotted, as `managedKeys`).
    public func applied(to root: JSONValue, managed: Set<String> = []) -> JSONValue {
        values.reduce(root) { root, entry in
            let id = entry.path.joined(separator: ".")
            guard !managed.contains(where: { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) else { return root }
            return SettingsController.replacing(entry.path, with: entry.value, in: root)
        }
    }

    /// The file's own density, unless a managed layer sets the density (`appearance.density` or
    /// `appearance.customDensity`, dotted, as `managedKeys`).
    public func density(under managed: Set<String>) -> DensityTokens? {
        let rows = [DensitySetting.configPath, CustomDensitySelectionSetting.configPath].map { $0.joined(separator: ".") }
        return managed.contains { key in rows.contains { $0 == key || $0.hasPrefix(key + ".") } } ? nil : density
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.isLoaded == rhs.isLoaded && lhs.isUnparsable == rhs.isUnparsable && lhs.diagnostics == rhs.diagnostics && lhs.corrected == rhs.corrected
            && lhs.density == rhs.density && lhs.fontFiles == rhs.fontFiles
            && lhs.values.map(\.path) == rhs.values.map(\.path) && lhs.values.map(\.value) == rhs.values.map(\.value)
    }

    private struct Reader {
        let file: String
        let folder: URL?
        var values: [(path: [String], value: JSONValue)] = []
        var diagnostics: [SettingsDiagnostic] = []
        var density: DensityTokens?
        var fontFiles: [URL] = []

        /// `"fonts"`: font files as `file:` paths (absolute, `~`, or relative to the themes folder), at most 32.
        mutating func readFonts(_ value: JSONValue) {
            guard case .array(let items) = value else { return refuse("fonts", value, "expected a list of file: paths") }
            for item in items.prefix(32) {
                guard case .string(let resolved) = picture(item), resolved.hasPrefix("file:/") else {
                    refuse("fonts", item, "expected a file: path")
                    continue
                }
                let url = URL(filePath: String(resolved.dropFirst("file:".count)))
                if !fontFiles.contains(url) { fontFiles.append(url) }
            }
        }

        /// `"density"`: a built-in (`basedOn`; else the one the file or `base` picks; else Default) with the file's
        /// `level`, `spacing`, `fontSize` and `tokens` over it. A token the playground does not list, or a value of the
        /// wrong type, is refused at its key; a number out of its range is clamped into it.
        mutating func readDensity(_ value: JSONValue, named title: String?, base: JSONValue) {
            guard case .object(let members) = value else { return refuse("density", value, "expected an object") }
            let picked = values.first { $0.path == DensitySetting.configPath }?.value.stringValue
                ?? base.value(at: DensitySetting.configPath)?.stringValue
            var preset = picked.flatMap(DensityPreset.init(rawValue:)) ?? .cozy
            if let raw = members["basedOn"] {
                guard let named = raw.stringValue.flatMap(DensityPreset.init(rawValue:)) else {
                    let choices = DensityPreset.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                    return refuse("density.basedOn", raw, "expected one of \(choices)")
                }
                preset = named
            }
            let name = title?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)
            var made = CustomDensitiesSetting.duplicate(preset.tokens, name: name.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "Theme",
                                                        existing: [])
            made.id = CustomDensitiesSetting.uniqueID(for: "theme \(made.name)", existing: [])
            for (key, raw) in members.sorted(by: { $0.key < $1.key }) where key != "basedOn" {
                switch key {
                case "level", "spacing", "fontSize":
                    guard let number = raw.doubleValue, number.isFinite else { refuse("density.\(key)", raw, "expected a number"); continue }
                    if key == "level" {
                        made.level = min(max(number, DensityTokens.levelRange.lowerBound), DensityTokens.levelRange.upperBound)
                    } else if let entry = DensityTokenCatalog.entry(key) {
                        made = DensityTokenCatalog.setting(entry, to: number, in: made)
                    }
                case "tokens":
                    guard case .object(let tokens) = raw else { refuse("density.tokens", raw, "expected an object"); continue }
                    for (token, written) in tokens.sorted(by: { $0.key < $1.key }) {
                        guard let entry = DensityTokenCatalog.entry(token), entry.field == .token else {
                            refuse("density.tokens.\(token)", written, "not a density token; the Density Playground lists them")
                            continue
                        }
                        guard let number = written.doubleValue, number.isFinite else {
                            refuse("density.tokens.\(token)", written, "expected a number")
                            continue
                        }
                        made = DensityTokenCatalog.setting(entry, to: number, in: made)
                    }
                default:
                    refuse("density.\(key)", raw, "expected basedOn, level, spacing, fontSize or tokens")
                }
            }
            density = made
        }

        /// A `file:` or `folder:` background relative to the themes folder, or at `~`, as an absolute
        /// path; any other value as written.
        private func picture(_ value: JSONValue) -> JSONValue {
            guard let raw = value.stringValue,
                  let prefix = ["file:", "folder:"].first(where: { raw.hasPrefix($0) }) else { return value }
            let path = String(raw.dropFirst(prefix.count))
            guard !path.isEmpty, !path.hasPrefix("/") else { return value }
            if path == "~" || path.hasPrefix("~/") { return .string(prefix + NSString(string: path).expandingTildeInPath) }
            guard let folder else { return value }
            return .string(prefix + folder.appending(path: path).standardizedFileURL.path)
        }

        /// A refused entry of the file at its key (`colors.background` for a color). The file itself
        /// (missing, unreadable) is `path` "": cmux-next.json's `appearance.themeFile` names it.
        private mutating func refuse(_ path: String, _ value: JSONValue?, _ message: String) {
            guard !path.isEmpty else {
                return diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: ThemeFileSetting.configPath.joined(separator: "."), message: message))
            }
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: message, file: file, value: value?.compactText))
        }
    }
}
