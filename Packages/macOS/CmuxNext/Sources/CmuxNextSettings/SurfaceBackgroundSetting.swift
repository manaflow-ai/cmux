public import CmuxNextDesign

/// `appearance.surfaces.<surface>.color` and `.opacity` in cmux.json
/// (Lawrence R55, plans/cmux-next/surface-backgrounds.md): one color and one
/// opacity per `SurfaceKind`. An absent key is the default, the window's
/// own color or opacity, so with no keys every surface shows the window's
/// one backdrop (R48).
public nonisolated enum SurfaceBackgroundSetting {
    /// `appearance.surfaces`.
    public static let rootPath = ["appearance", "surfaces"]
    /// The opacity range (a fraction, as `appearance.backgroundOpacity`).
    public static let opacityRange: ClosedRange<Double> = 0...1

    /// `appearance.surfaces.<surface>.color`.
    public static func colorPath(_ kind: SurfaceKind) -> [String] { rootPath + [kind.rawValue, "color"] }
    /// `appearance.surfaces.<surface>.opacity`.
    public static func opacityPath(_ kind: SurfaceKind) -> [String] { rootPath + [kind.rawValue, "opacity"] }

    /// Every dotted key, color and opacity per surface.
    public static var keys: [String] {
        SurfaceKind.allCases.flatMap { [colorPath($0), opacityPath($0)] }.map { $0.joined(separator: ".") }
    }

    /// A bad value keeps that field's default and adds a diagnostic at its
    /// key; unknown surfaces and fields are reported too.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SurfaceBackgrounds {
        guard let value = root.value(at: rootPath) else { return .none }
        let rootKey = rootPath.joined(separator: ".")
        guard case .object(let surfaces) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: rootKey, message: "expected an object"))
            return .none
        }
        var overrides: [SurfaceKind: SurfaceBackground] = [:]
        for (name, entry) in surfaces {
            let path = "\(rootKey).\(name)"
            guard let kind = SurfaceKind(rawValue: name) else {
                let names = SurfaceKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "unknown surface; expected one of \(names)"))
                continue
            }
            guard case .object(let fields) = entry else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object"))
                continue
            }
            var background = SurfaceBackground()
            for (field, fieldValue) in fields {
                switch field {
                case "color":
                    if let text = fieldValue.stringValue, let color = PaneChromeConfigParser.color(hex: text) {
                        background.color = color
                    } else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).color",
                                                              message: "expected \"#RRGGBB\" or \"#RRGGBBAA\""))
                    }
                case "opacity":
                    if case .number(let number) = fieldValue, opacityRange.contains(number) {
                        background.opacity = number
                    } else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).opacity",
                                                              message: "expected a number from 0 to 1, such as 0.85"))
                    }
                default:
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(field)",
                                                          message: "unknown field; expected \"color\" or \"opacity\""))
                }
            }
            if !background.isEmpty { overrides[kind] = background }
        }
        return SurfaceBackgrounds(overrides: overrides)
    }
}
