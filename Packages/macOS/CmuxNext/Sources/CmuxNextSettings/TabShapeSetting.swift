public import CmuxNextDesign

/// `appearance.tabShape` in cmux-next.json (Settings > Appearance > Panes, Tab Shape): "block" (the default) or
/// "rounded" (`TabShape`), for the tabs of every tab bar and the rows of the sidebar; the gooey look is
/// `appearance.cornerFlush` "flush-goo" (`CornerFlushSetting`), which a block shape lets reach the sidebar. A missing key is
/// the default; a bad value is the default plus a diagnostic. A theme file can set it like any other `appearance.*`
/// key. Its path, default and choices are generated from schemas/settings/source/appearance.json.
public nonisolated struct TabShapeSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> TabShape {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let shape = TabShape(rawValue: text) else {
            let choices = TabShape.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return shape
    }

    /// The shape `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> TabShape {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.tabShape` into `design`, writing only a change.
    static func applyTabShape(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let shape = TabShapeSetting.effective(in: snapshot)
        if design.tabShape != shape { design.tabShape = shape }
    }
}
