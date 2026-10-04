public import CmuxNextDesign
import CoreGraphics

/// `sidebar.border` (on/off) and `sidebar.borderWidth` (points, 0.5 to 4;
/// unset is the divider hairline). A bad value is skipped with a diagnostic.
public nonisolated enum SidebarBorderSetting {
    public static let borderPath = ["sidebar", "border"]
    public static let widthPath = ["sidebar", "borderWidth"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarBorder {
        var border = SidebarBorder()
        if let value = root.value(at: borderPath) {
            if let shows = value.boolValue {
                border.shows = shows
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.border", message: "expected true or false"))
            }
        }
        if let value = root.value(at: widthPath) {
            let range = SidebarBorder.widthRange
            if let number = value.doubleValue, number.isFinite {
                let width = CGFloat(number)
                if !range.contains(width) {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.borderWidth",
                                                          message: "clamped to \(range.lowerBound)...\(range.upperBound) points"))
                }
                border.width = min(max(width, range.lowerBound), range.upperBound)
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.borderWidth", message: "expected a number of points"))
            }
        }
        return border
    }
}
