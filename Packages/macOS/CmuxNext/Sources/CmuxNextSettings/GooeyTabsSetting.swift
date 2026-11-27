public import CmuxNextDesign

/// `appearance.gooeyTabs` in cmux-next.json (Settings > Appearance, Gooey Tabs): "off" (the default), "subtle" or
/// "full" (`GooeyTabs`; plans/cmux-next/gooey-tabs.md). Leo, 2026-11-23: "presumably a less intense version should
/// have a better case to be the default. so you guys need to try that. like. subtle goo." A missing key is the
/// default; a bad value is the default plus a diagnostic. Subtle and full make the corner flush-goo and the title
/// area Subtle Tone as effective values (`CornerFlush.current`, `DesignSettings.effectiveTitleAreaTone`): the
/// applier writes this key alone. Its path, default and choices are generated from
/// schemas/settings/source/appearance.json.
public nonisolated struct GooeyTabsSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> GooeyTabs {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let level = GooeyTabs(rawValue: text) else {
            let choices = GooeyTabs.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return level
    }

    /// The level `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> GooeyTabs {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.gooeyTabs` into `design`, writing only a change.
    static func applyGooeyTabs(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let level = GooeyTabsSetting.effective(in: snapshot)
        if design.gooeyTabs != level { design.gooeyTabs = level }
    }
}
