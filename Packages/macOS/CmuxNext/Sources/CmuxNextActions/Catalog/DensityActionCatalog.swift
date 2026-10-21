// Density (plans/cmux-next/density-DESIGN.md): one palette row per built-in density, titled
// "Density: <name>", plus Set Density (any density, custom ones too: `cmux density set`) and
// New Custom Density (`cmux density create`). Custom densities also get their own palette rows
// from the App (`DensityPaletteRows`). Titles live in SettingsActions.xcstrings (21 languages).

nonisolated enum DensityActionCatalog: ActionCatalogGroup {
    /// The action that applies the built-in density `preset` (`appearance.density.<id>`).
    static func presetID(_ preset: String) -> ActionID { ActionID(rawValue: "appearance.density.\(preset)") }

    static func descriptors() -> [ActionDescriptor] {
        let density = ActionArgument(
            name: "density", title: String(localized: "argument.density", defaultValue: "Density", table: "SettingsActions", bundle: .module),
            kind: .string, suggestions: ActionSuggestions(source: ActionSuggestions.densities, pinned: presetCases))
        let name = ActionArgument(name: "name", title: String(localized: "argument.density.name", defaultValue: "Name", table: "SettingsActions", bundle: .module),
                                  kind: .string)
        let basedOn = ActionArgument(
            name: "basedOn", title: String(localized: "argument.density.basedOn", defaultValue: "Based On", table: "SettingsActions", bundle: .module),
            kind: .string, isRequired: false, suggestions: ActionSuggestions(source: ActionSuggestions.densities, pinned: presetCases))
        let fontSize = ActionArgument(
            name: "fontSize", title: String(localized: "argument.density.fontSize", defaultValue: "Text Size", table: "SettingsActions", bundle: .module),
            kind: .string, isRequired: false)
        let keywords = ["density", "size", "spacing", "rows", "appearance", "font"]
        return presets.map { preset in
            ActionDescriptor(id: presetID(preset.id), title: preset.title, keywords: keywords + preset.keywords, category: .settings,
                             symbol: preset.symbol, surfaces: [.palette], cliName: preset.cli)
        } + [
            ActionDescriptor(
                id: "appearance.density.set",
                title: String(localized: "action.appearance.density.set", defaultValue: "Set Density…", table: "SettingsActions", bundle: .module),
                keywords: keywords + ["custom", "choose", "pick"], category: .settings, symbol: "slider.vertical.3",
                surfaces: [.palette], arguments: [density], cliName: "density set"
            ),
            ActionDescriptor(
                id: "appearance.density.create",
                title: String(localized: "action.appearance.density.create", defaultValue: "New Custom Density…", table: "SettingsActions", bundle: .module),
                keywords: keywords + ["custom", "new", "create", "duplicate"], category: .settings, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette], arguments: [name, basedOn, fontSize], cliName: "density create"
            ),
        ]
    }

    private struct Preset {
        let id: String, title: String, symbol: String, cli: String, keywords: [String]
    }

    /// The built-ins, densest first. Compact and Comfortable keep their older CLI names.
    private static var presets: [Preset] {
        [
            Preset(id: "ultraCompact", title: String(localized: "action.appearance.density.ultraCompact", defaultValue: "Density: Ultra-compact", table: "SettingsActions", bundle: .module),
                   symbol: "rectangle.compress.vertical", cli: "density use-ultra-compact", keywords: ["ultra", "compact", "dense", "tight", "smallest"]),
            Preset(id: "compact", title: String(localized: "action.appearance.density.compact", defaultValue: "Density: Compact", table: "SettingsActions", bundle: .module),
                   symbol: "rectangle.compress.vertical", cli: "settings use-compact-density", keywords: ["compact", "dense", "default"]),
            Preset(id: "cozy", title: String(localized: "action.appearance.density.cozy", defaultValue: "Density: Cozy", table: "SettingsActions", bundle: .module),
                   symbol: "rectangle", cli: "density use-cozy", keywords: ["cozy", "medium", "middle"]),
            Preset(id: "comfortable", title: String(localized: "action.appearance.density.comfortable", defaultValue: "Density: Comfortable", table: "SettingsActions", bundle: .module),
                   symbol: "rectangle.expand.vertical", cli: "settings use-comfortable-density", keywords: ["comfortable", "roomy", "larger"]),
            Preset(id: "spacious", title: String(localized: "action.appearance.density.spacious", defaultValue: "Density: Spacious", table: "SettingsActions", bundle: .module),
                   symbol: "rectangle.expand.vertical", cli: "density use-spacious", keywords: ["spacious", "large", "big", "accessible"]),
        ]
    }

    /// The built-ins as argument values, for the Set Density and Based On pickers.
    private static var presetCases: [ActionEnumCase] {
        presets.map { ActionEnumCase(value: $0.id, title: $0.title.replacingOccurrences(of: densityPrefix, with: "")) }
    }

    /// The title prefix the built-in rows share ("Density: "), localized.
    static var densityPrefix: String {
        String(localized: "action.appearance.density.prefix", defaultValue: "Density: ", table: "SettingsActions", bundle: .module)
    }
}
