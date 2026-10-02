public import CmuxNextDesign

/// Parses the sidebar section settings (`sidebar.*` in cmux.json). A
/// missing key is its default; a bad value is the default plus a diagnostic.
public nonisolated enum SidebarSectionsSetting {
    public static let lookPath = ["sidebar", "sectionLook"]
    public static let topSharePath = ["sidebar", "topBandMaxShare"]
    public static let bottomSharePath = ["sidebar", "bottomBandMaxShare"]
    public static let scrollPath = ["sidebar", "stickyBandsScroll"]
    /// The looks the setting accepts (CmuxNextSidebar.SectionsLookVariant).
    public static let looks = ["quiet", "card", "tray", "lines", "linesIcons"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarSectionsPreferences {
        var result = SidebarSectionsPreferences.defaults
        if let value = root.value(at: lookPath) {
            if let text = value.stringValue, looks.contains(text) {
                result.look = text
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.sectionLook",
                                                      message: "expected one of " + looks.map { "\"\($0)\"" }.joined(separator: ", ")))
            }
        }
        result.topBandMaxShare = share(root, topSharePath, "sidebar.topBandMaxShare", fallback: result.topBandMaxShare, &diagnostics)
        result.bottomBandMaxShare = share(root, bottomSharePath, "sidebar.bottomBandMaxShare", fallback: result.bottomBandMaxShare, &diagnostics)
        if let value = root.value(at: scrollPath) {
            if let flag = value.boolValue {
                result.stickyBandsScroll = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.stickyBandsScroll", message: "expected true or false"))
            }
        }
        return result
    }

    private static func share(_ root: JSONValue, _ path: [String], _ name: String, fallback: Double,
                              _ diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, SidebarSectionsPreferences.shareRange.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: name,
                                                  message: "expected a share of the sidebar height from 0.1 to 0.9, such as 0.33"))
            return fallback
        }
        return number
    }
}
