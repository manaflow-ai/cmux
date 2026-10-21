public import CmuxNextDesign

/// `appearance.glass` in cmux.json (`GlassLensMode`, plans/cmux-next/glass-lens-DESIGN.md):
/// "lens" (the default) bends the wallpaper at the rim of web glass surfaces, "plain" only blurs
/// it, "spectrum" adds a chromatic split at the rim. Reduce Transparency and Low Power Mode draw
/// plain glass whatever it says. A missing key is the default; a bad value is the default plus a
/// diagnostic.
public nonisolated struct GlassSetting: Sendable {
    public let configPath = ["appearance", "glass"]
    public let fallback: GlassLensMode = .lens

    public init() {}

    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> GlassLensMode {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let mode = GlassLensMode(rawValue: text) else {
            let choices = GlassLensMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return mode
    }

    /// The Settings row: a segmented Lens / Plain Glass / Spectrum choice.
    func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .appearance, group: group,
            title: SettingsText.keyed("settings.appearance.glass", "Glass"),
            help: SettingsText.keyed("settings.appearance.glass.help",
                                     "How glass surfaces bend the wallpaper behind them. Plain Glass blurs only. Reduce Transparency and Low Power Mode use Plain Glass."),
            kind: .choice([
                SettingChoice(GlassLensMode.lens.rawValue, SettingsText.keyed("settings.choice.glassLens", "Lens")),
                SettingChoice(GlassLensMode.plain.rawValue, SettingsText.keyed("settings.choice.glassPlain", "Plain Glass")),
                SettingChoice(GlassLensMode.spectrum.rawValue, SettingsText.keyed("settings.choice.glassSpectrum", "Spectrum")),
            ]),
            default: .string(fallback.rawValue),
            keywords: ["glass", "liquid glass", "lens", "refraction", "refract", "spectrum", "chromatic", "dispersion",
                       "blur", "wallpaper", "transparency"]
        )
    }
}
