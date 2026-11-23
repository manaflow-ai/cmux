public import CmuxNextDesign

/// `appearance.cornerFlush` in cmux-next.json (Settings > Appearance > Panes, Selected Tab Shape): how the selected
/// tab meets the content card (`CornerFlush`): "off" (the pill), "flush", "flush-tight" or "flush-goo". Leo,
/// 2026-11-18: "the sort of like gooey kind of material design-ish aesthetic that we had, that we don't have as
/// default, but we have as a toggle maybe, and we can like do more stuff with that". A theme file and a setup can
/// set it like any other `appearance.*` key. A missing key is nil: the default, `flush` with no goo, over the stock
/// chrome only (`CornerFlush.current`; Leo, 2026-11-13: "lawrence wanted no goo by default"); a bad value is nil
/// plus a diagnostic. The Debug Settings tunable `chrome.cornerFlush` still overrides it in DEV and NIGHTLY. Its
/// path, default and choices are generated from schemas/settings/source/appearance.json.
public nonisolated struct CornerFlushSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> CornerFlush? {
        guard let value = root.value(at: configPath) else { return nil }
        guard let text = value.stringValue, let flush = CornerFlush(rawValue: text) else {
            let choices = CornerFlush.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return nil
        }
        return flush
    }

    /// The corner `snapshot` picks, or nil for the default.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> CornerFlush? {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.cornerFlush` into `design`, writing only a change.
    static func applyCornerFlush(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let flush = CornerFlushSetting.effective(in: snapshot)
        if design.cornerFlush != flush { design.cornerFlush = flush }
    }
}
