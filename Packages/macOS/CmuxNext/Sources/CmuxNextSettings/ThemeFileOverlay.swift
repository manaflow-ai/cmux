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

    /// Keys a theme file reads that are not settings (cmux-config `theme_file::RESERVED_KEYS`; `motion` is read by the daemon).
    static let reservedKeys: Set<String> = ["name", "description", "$schema", "colors", "ghostty", "density", "slots", "fonts", "motion"]
    /// Look keys that are no part of a look: the theme file itself, the star list and its rotation,
    /// per-machine and per-display maps, the sun location (where this Mac is), what each background mode
    /// last showed and the backgrounds shown before, and the saved custom densities.
    static let excludedKeys: Set<String> = [
        ThemeFileSetting.configPath.joined(separator: "."), "appearance.favoriteThemes", "appearance.rotateFavoriteThemes",
        "appearance.machineColors", "appearance.displayBackgrounds", "appearance.displayBackgroundRotations",
        "appearance.customDensities", "appearance.backgroundLocation", "appearance.backgroundMemory",
        "appearance.backgroundPlacement", "appearance.backgroundRecents",
        ThemeFileExceptionsSetting.configPath.joined(separator: "."),
    ]
    /// Look key prefixes; `agentPane.display.font.` is the agent chat's typography (a font pack's
    /// families and face files).
    static let lookPrefixes = ["appearance.", "agentPane.display.font.", "ui.animation", "ui.calm", "ui.paneAnimations",
                               "ui.reducedBackgrounds", "browser.omnibar.glass", "app.uiScale"]
    /// Look keys outside those prefixes: the terminal font and the chat code font; the sidebar's shape, edges,
    /// text, group headers and buttons, whether its menus are drawn (so the menu look styles them), the sidebar
    /// look (`SidebarLookPreset`), and how its rows draw (status icons, timestamps, colors, grouping), so one file
    /// restyles the sidebar as a whole (the shipped `minimal-sessions`); the tab strip's and titlebar's buttons and
    /// inactive tabs; pane corners; the agent chat's text sizes, sender marks and Session Info (Leo, 2026-11-18:
    /// "you guys should be customizing the tabs/sidebars a lot deeper too. prob likewise the session info and the
    /// top right buttons as well"); and the transcript look and its tokens
    /// (docs/cmux-next/transcript-customization.md). Keep in step with cmux-config's `LOOK_KEYS`.
    static let lookKeys: Set<String> = [
        "terminal.fontFamily", "agentPane.display.code.family", "terminal.fontSize",
        "sidebar.style", "sidebar.border", "sidebar.borderWidth", "sidebar.sectionLook", "sidebar.look",
        "sidebar.drawnMenus",
        "sidebar.density",
        "sidebar.textSize", "sidebar.groupHeader.background", "sidebar.groupPalette", "sidebar.groupGradient",
        "sidebar.showSearchButton", "sidebar.showProfileControl", "sidebar.showNewWorkspaceChooser",
        "sidebar.controlsOnHover", "sidebar.detailedStatusIcons", "sidebar.showColors",
        "sidebar.showTimestamps", "workspaceColors.indicatorStyle", "sidebar.groupBy",
        "sidebar.groupHeader.memberCount", "sidebar.groupHeader.unreadCount", "sidebar.spacesVisibility",
        "tabs.toolbarButtons", "tabs.plusButton", "window.titlebarButtons", "focus.inactiveTabStyle",
        "layout.paneCornerRadius", "layout.cornerPadding", "layout.paneBorderWidth",
        "agentPane.display.sessionInfo.placement", "agentPane.display.font.preset", "agentPane.display.font.ui",
        "agentPane.display.font.size", "agentPane.display.font.lineHeight", "agentPane.display.code.scale",
        "agentPane.display.senderIcon.lead", "agentPane.display.senderIcon.badge", "agentPane.display.senderIcon.corner",
        "agentPane.display.trayHandle", "agentPane.display.transcriptLook", "agentPane.display.transcriptTokens",
    ]
    /// The workspace row's own keys (`sidebar.workspaceRow.<name>`), one segment only: the per-kind overrides
    /// (`sidebar.workspaceRow.<kind>.<name>`) stay in cmux-next.json.
    static let rowPrefix = "sidebar.workspaceRow."

    /// Whether a theme file may set `descriptor`: a look setting an agent may set too.
    public static func isLook(_ descriptor: SettingDescriptor) -> Bool {
        let id = descriptor.id
        return SettingsSchema.agentSettableKeys.contains(id) && !excludedKeys.contains(id)
            && (lookKeys.contains(id) || lookPrefixes.contains { id.hasPrefix($0) } || isRowKey(id))
    }

    static func isRowKey(_ id: String) -> Bool {
        guard id.hasPrefix(rowPrefix) else { return false }
        let name = id.dropFirst(rowPrefix.count)
        return !name.isEmpty && !name.contains(".")
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
        var reader = Reader(file: "\(ThemeFileSetting.folderName)/\(name).\(ThemeFileSetting.fileExtension)", folder: folder)
        isLoaded = reader.read(source, base: base)
        isUnparsable = reader.isUnparsable
        values = reader.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        diagnostics = reader.diagnostics
        corrected = reader.corrected
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
        var corrected: [String] = []
        var density: DensityTokens?
        var fontFiles: [URL] = []
        var isUnparsable = false

        /// Reads the file's text; false when there is none or it is not a JSON object.
        mutating func read(_ source: Result<String, any Error>?, base: JSONValue) -> Bool {
            guard let source else {
                refuse("", nil, "there is no file \(file)")
                return false
            }
            let parsed: JSONValue
            var text: String?
            do {
                text = try source.get()
                parsed = try JSONC.parse(text ?? "")
            } catch {
                unreadable(JSONC.problem(error, in: text))
                return false
            }
            guard case .object(let members) = parsed else {
                unreadable("root is not an object")
                return false
            }
            for (key, value) in members.sorted(by: { $0.key < $1.key }) where !ThemeFileOverlay.reservedKeys.contains(key) {
                walk(value, path: CmuxConfigFile.keyPath(from: key))
            }
            readColors(members, base: base)
            if let value = members["density"] { readDensity(value, named: members["name"]?.stringValue, base: base) }
            if let value = members["fonts"] { readFonts(value) }
            return true
        }

        /// `"fonts"`: font files as `file:` paths (absolute, `~`, or relative to the themes folder), at most 32.
        private mutating func readFonts(_ value: JSONValue) {
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
        private mutating func readDensity(_ value: JSONValue, named title: String?, base: JSONValue) {
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

        private mutating func take(_ descriptor: SettingDescriptor, _ written: JSONValue) {
            guard ThemeFileOverlay.isLook(descriptor) else {
                return refuse(descriptor.id, written, "a theme file sets only look settings")
            }
            let pictures = [BackdropSelectionSetting.configPath, BackdropSelectionSetting.lightPath, BackdropSelectionSetting.darkPath]
            var value = pictures.contains(descriptor.path) ? picture(written) : written
            // A font pack's face files resolve as pictures do: `file:../fonts/x.woff2`.
            if descriptor.path == AgentPaneDisplaySettingsSchema.facesPath, case .object(let faces) = written {
                value = .object(faces.mapValues(picture))
            }
            guard descriptor.accepts(value) else { return refuse(descriptor.id, value, OmnibarSettingsSchema.expectation(descriptor)) }
            // A key written twice (nested and dotted) keeps the later one in key order.
            values.removeAll { $0.path == descriptor.path }
            values.append((descriptor.path, value))
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

        /// The file is there but does not parse: one `.unreadableFile` notice of the file whatever the
        /// error says (its fingerprint is the file and the kind), worded as cmux-next.json's.
        private mutating func unreadable(_ problem: String) {
            isUnparsable = true
            diagnostics.append(SettingsDiagnostic(kind: .unreadableFile, path: "", message: problem, file: file))
        }

        /// A refused entry of the file at its key (`colors.background` for a color). The file itself
        /// (missing, unreadable) is `path` "": cmux-next.json's `appearance.themeFile` names it.
        private mutating func refuse(_ path: String, _ value: JSONValue?, _ message: String) {
            guard !path.isEmpty else {
                return diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: ThemeFileSetting.configPath.joined(separator: "."), message: message))
            }
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: message, file: file, value: value?.compactText))
        }

        /// `colors` and `ghostty` as `appearance.themeEdits` of the terminal theme the file (or `base`)
        /// names, over `base`'s edits; then the contrast guard over every theme the file colors.
        private mutating func readColors(_ members: [String: JSONValue], base: JSONValue) {
            let editsPath = ThemeEditsSetting.configPath
            let ownEdits = values.first { $0.path == editsPath }?.value.objectValue ?? [:]
            var colors: [String: String] = [:]
            if let ghostty = members["ghostty"] { readGhostty(ghostty, into: &colors) }
            if let value = members["colors"] { readColorMap(value, into: &colors) }
            var themes = Set(ownEdits.keys.compactMap { key in key.lastIndex(of: "/").map { String(key[..<$0]) } })
            let shown = base.value(at: editsPath)?.objectValue ?? [:]
            var edits = shown.merging(ownEdits) { $1 }
            if !colors.isEmpty {
                let themePath = AppThemeSetting.configPath
                let theme = values.first { $0.path == themePath }?.value.stringValue ?? base.value(at: themePath)?.stringValue
                if let theme, let spec = ThemeSpec(theme) {
                    for name in Set([spec.light, spec.dark]) {
                        themes.insert(name)
                        for (token, color) in colors { edits[ThemeEditsSetting.key(theme: name, token: token)] = .string(color) }
                    }
                } else {
                    refuse("colors", nil, "colors need appearance.theme: they edit that terminal theme")
                }
            }
            guard !themes.isEmpty else { return }
            for name in themes.sorted() { guardContrast(&edits, shown: shown, theme: name) }
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

        /// A foreground under 4.5:1 on its background takes the app theme's text color for them
        /// (`AppTheme.derive`, the contract every chrome token meets). A pair the settings already
        /// show (`shown`, their own edits) stays as it is: a file that copies the settings changes nothing.
        private mutating func guardContrast(_ edits: inout [String: JSONValue], shown: [String: JSONValue], theme: String) {
            func color(_ token: String, of edits: [String: JSONValue]) -> ThemeRGB? {
                edits[ThemeEditsSetting.key(theme: theme, token: token)]?.stringValue.flatMap(ThemeRGB.init(cssHex:))
            }
            guard let background = color("background", of: edits), let foreground = color("foreground", of: edits),
                  foreground.contrast(with: background) < AppTheme.textMinimum else { return }
            let isShown = color("background", of: shown).map(AppTheme.hex) == AppTheme.hex(background)
                && color("foreground", of: shown).map(AppTheme.hex) == AppTheme.hex(foreground)
            guard !isShown else { return }
            let written = AppTheme.hex(foreground)
            let fixed = AppTheme.hex(AppTheme.derive(background: background, foreground: foreground, palette: (0..<16).map { color(String($0), of: edits) })[.text])
            let ratio = (foreground.contrast(with: background) * 10).rounded() / 10
            diagnostics.append(SettingsDiagnostic(
                kind: .correctedValue, path: ThemeFileSetting.configPath.joined(separator: "."),
                message: "\(theme)'s foreground \(written) is \(ratio):1 on its background, so cmux shows \(fixed) (4.5:1 or more)",
                file: file, value: JSONValue.string(written).compactText))
            edits[ThemeEditsSetting.key(theme: theme, token: "foreground")] = .string(fixed)
            if !corrected.contains("foreground") { corrected.append("foreground") }
        }
    }
}
