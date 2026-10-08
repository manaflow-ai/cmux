import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow

/// What the React Settings page shows beside the schema rows (R82 commit 2): `cmux.settings.host.lists`.
/// Spaces (nil when this daemon has no profiles), saved machines, browser profiles, and the
/// profile color swatches. Edits run catalog actions (`browserProfile.*`) through
/// `cmux.app.action.run`, the same path as the palette and the CLI.
extension SettingsWindowService {
    func pageHostLists() -> JSONValue {
        [
            "rooms": rooms.map { .array($0.map(Self.listRow)) } ?? .null,
            "machines": .array(machines.map(Self.listRow)),
            "browser_profiles": .array(browserProfiles.map { profile in
                [
                    "id": .string(profile.id), "name": .string(profile.name),
                    "color": profile.color.map(JSONValue.string) ?? .null, "icon": profile.icon.map(JSONValue.string) ?? .null,
                    "is_default": .bool(profile.isDefault), "source": profile.source.map(JSONValue.string) ?? .null,
                ]
            }),
            "profile_colors": .array(GroupColor.allCases.map { color in
                ["name": .string(color.rawValue), "swatch": .string(Self.hex(color.swatch)), "fill": .string(Self.hex(color.fill))]
            }),
            // R82 commit 4: theme levels of the active window, terminal facts, the settings file
            // and the wallpaper choices (thumbnails at cmux-page://cmux.settings/backdrop/<id>).
            "theme": [
                "levels": .array(themeLevels.map { .string($0.rawValue) }),
                "current": .object(Dictionary(uniqueKeysWithValues: themeLevels.map { level in
                    (level.rawValue, theme(at: level).map(JSONValue.string) ?? .null)
                })),
                // The Ghostty config's own theme, for the preview of "Use Ghostty Config": the app
                // scope's colors while appearance.theme is unset (null while it names a theme).
                "config": services.settings?.snapshot.appTheme == nil ? Self.themeJSON(ThemeScope.app.input) : .null,
            ],
            "terminal": ["ghostty_config": .string(ghosttyConfigPath), "shell_integration": shellIntegration.map(JSONValue.string) ?? .null],
            // R92: the Ghostty lines cmux does not apply (the socket's `ghostty.diagnostics` list).
            "ghostty_diagnostics": GhosttyDiagnosticsModel.shared.diagnostics.map { .array($0.map(GhosttyDiagnosticsControl.json)) } ?? .null,
            // Computer Use Setup (Agents): the helper's grants, the same state as the palette action.
            "computer_use": services.computerUseSetup.pageJSON,
            "settings_file": services.settings.map { .string($0.file.url.path(percentEncoded: false)) } ?? .null,
            "backdrops": .array(Self.backdrops.choices.map { choice in
                ["id": .string(choice.id), "title": .string(choice.title), "attribution": .string(choice.attribution)]
            }),
            "derived": .object(pageDerivedNumbers()),
        ]
    }

    /// Where unset number rows' sliders sit, by schema key: the window opacity the theme resolved.
    func pageDerivedNumbers() -> [String: JSONValue] {
        var derived: [String: JSONValue] = [:]
        for path in [WindowBackgroundSetting.opacityPath] {
            guard let id = SettingsSchema.descriptor(for: path)?.id, let value = derivedNumber(at: path) else { continue }
            derived[id] = .number(value)
        }
        return derived
    }

    /// The wallpaper grid's choices (bounded: a large Desktop Pictures folder stays quick).
    static let backdrops = BackdropCatalog(systemDirectory: URL(fileURLWithPath: "/System/Library/Desktop Pictures"), fileManager: .default)

    /// The theme picker's write: the same theme actions as the palette, at `level` of the active
    /// window; nil `spec` returns the level to the Ghostty config.
    func setPageTheme(level: String, spec: String?) throws {
        guard let level = SettingsThemeLevel(rawValue: level), themeLevels.contains(level) else {
            throw ActionFailure.invalidTarget(level)
        }
        setTheme(spec, at: level)
    }

    /// Terminal colors as the page reads a theme (`GhosttyTheme`, unnamed: the page labels it).
    static func themeJSON(_ input: ThemeInput) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(""),
            "background": .string(AppTheme.hex(input.background)),
            "foreground": .string(AppTheme.hex(input.foreground)),
            "palette": .array((0..<16).map { $0 < input.palette.count ? .string(AppTheme.hex(input.palette[$0])) : .null }),
        ]
        if let selection = input.selectionBackground { object["selectionBackground"] = .string(AppTheme.hex(selection)) }
        if let selected = input.selectionForeground { object["selectionForeground"] = .string(AppTheme.hex(selected)) }
        return .object(object)
    }

    private static func listRow(_ row: SettingsListRow) -> JSONValue {
        ["id": .string(row.id), "title": .string(row.title), "subtitle": row.subtitle.map(JSONValue.string) ?? .null,
         "active": .bool(row.isActive)]
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02X", min(max($0, 0), 255)) }.joined()
    }
}
