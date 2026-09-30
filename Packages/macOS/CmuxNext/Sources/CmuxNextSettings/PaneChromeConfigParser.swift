public import CmuxNextDesign
import CoreGraphics

/// Parses the pane chrome keys under `layout` in cmux.json:
/// `layout.panePadding` (points, 0 allowed), `layout.paneCornerRadius`
/// (points, 0 allowed) and `layout.paneBorder` ("subtle" or "none"). A bad
/// value is skipped with a diagnostic and falls back to the default.
enum PaneChromeConfigParser {
    static func parse(_ root: JSONValue) -> (overrides: PaneChromeOverrides, diagnostics: [SettingsDiagnostic]) {
        var overrides = PaneChromeOverrides()
        var diagnostics: [SettingsDiagnostic] = []
        guard let layout = root["layout"] else { return (overrides, diagnostics) }
        guard case .object(let members) = layout else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout", message: "expected an object"))
            return (overrides, diagnostics)
        }
        overrides.padding = points(members["panePadding"], path: "layout.panePadding",
                                   range: PaneChromeOverrides.paddingRange, diagnostics: &diagnostics)
        overrides.cornerRadius = points(members["paneCornerRadius"], path: "layout.paneCornerRadius",
                                        range: PaneChromeOverrides.cornerRadiusRange, diagnostics: &diagnostics)
        if let value = members["paneBorder"] {
            if let text = value.stringValue, let style = PaneBorderStyle(rawValue: text) {
                overrides.border = style
            } else {
                let choices = PaneBorderStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.paneBorder", message: "expected \(choices)"))
            }
        }
        return (overrides, diagnostics)
    }

    private static func points(_ value: JSONValue?, path: String, range: ClosedRange<CGFloat>,
                               diagnostics: inout [SettingsDiagnostic]) -> CGFloat? {
        guard let value else { return nil }
        guard let number = value.doubleValue, number.isFinite else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected a number of points"))
            return nil
        }
        let points = CGFloat(number)
        if !range.contains(points) {
            diagnostics.append(SettingsDiagnostic(
                kind: .invalidValue, path: path,
                message: "clamped to \(Int(range.lowerBound))...\(Int(range.upperBound)) points"
            ))
        }
        return min(max(points, range.lowerBound), range.upperBound)
    }
}
