import CmuxNextDesign

/// `appearance.focusIndicator`, `appearance.tabBarBackground` and
/// `focus.inactiveTabStyle` in cmux.json. A missing key is the default with no diagnostic; a bad value
/// is the default plus a diagnostic.
enum PaneFocusSettings {
    static let focusIndicatorPath = ["appearance", "focusIndicator"]
    static let tabBarBackgroundPath = ["appearance", "tabBarBackground"]
    static let focusIndicatorFallback: FocusIndicator = .both
    static let tabBarBackgroundFallback: TabBarBackground = .window
    static let inactiveTabStylePath = ["focus", "inactiveTabStyle"]
    static let inactiveTabStyleFallback: InactiveTabStyle = .fade

    static func parse<T: RawRepresentable & CaseIterable>(_ root: JSONValue, at path: [String], fallback: T)
        -> (T, SettingsDiagnostic?) where T.RawValue == String {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue, let parsed = T(rawValue: text) else {
            let choices = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (parsed, nil)
    }
}
