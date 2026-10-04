public import CmuxNextDesign
public import CmuxTheme

/// `appearance.surfaceBackgrounds` stores optional `#RRGGBB`/`#RRGGBBAA`
/// overrides. Missing entries inherit the one per-theme surface token.
public enum SurfaceBackgroundSetting {
    public static let path = ["appearance", "surfaceBackgrounds"]
    private static let names = ["sidebar", "tabStrip", "terminal", "browser", "internalPage", "agentPane", "splitDivider", "settings"]

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SurfaceBackgroundOverrides {
        guard let value = root.value(at: path) else { return SurfaceBackgroundOverrides() }
        guard let object = value.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected an object of surface colors"))
            return SurfaceBackgroundOverrides()
        }
        var result = SurfaceBackgroundOverrides()
        for name in names {
            guard let value = object[name] else { continue }
            if value.isNull { continue }
            guard let text = value.stringValue, let color = ThemeRGB(cssHex: text) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue,
                                                      path: "appearance.surfaceBackgrounds.\(name)",
                                                      message: "expected #RRGGBB or #RRGGBBAA"))
                continue
            }
            switch name {
            case "sidebar": result.sidebar = color
            case "tabStrip": result.tabStrip = color
            case "terminal": result.terminal = color
            case "browser": result.browser = color
            case "internalPage": result.internalPage = color
            case "agentPane": result.agentPane = color
            case "splitDivider": result.splitDivider = color
            case "settings": result.settings = color
            default: break
            }
        }
        return result
    }
}
