public import CmuxNextDesign
public import CmuxTheme

/// `appearance.surfaceBackgrounds` stores optional `#RRGGBB`/`#RRGGBBAA`
/// overrides. Missing entries inherit the one per-theme surface token.
public enum SurfaceBackgroundSetting {
    public static let path = ["appearance", "surfaceBackgrounds"]
    private static let names: [(String, WritableKeyPath<SurfaceBackgroundOverrides, ThemeRGB?>)] = [
        ("sidebar", \.sidebar), ("tabStrip", \.tabStrip), ("terminal", \.terminal),
        ("browser", \.browser), ("internalPage", \.internalPage), ("agentPane", \.agentPane),
        ("splitDivider", \.splitDivider), ("settings", \.settings)
    ]

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SurfaceBackgroundOverrides {
        guard let value = root.value(at: path) else { return SurfaceBackgroundOverrides() }
        guard let object = value.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected an object of surface colors"))
            return SurfaceBackgroundOverrides()
        }
        var result = SurfaceBackgroundOverrides()
        for (name, keyPath) in names {
            guard let value = object[name] else { continue }
            if value.isNull { result[keyPath: keyPath] = nil; continue }
            guard let text = value.stringValue, let color = ThemeRGB(cssHex: text) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue,
                                                      path: "appearance.surfaceBackgrounds.\(name)",
                                                      message: "expected #RRGGBB or #RRGGBBAA"))
                continue
            }
            result[keyPath: keyPath] = color
        }
        return result
    }
}
