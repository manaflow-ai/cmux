/// `browser.defaultEngine` in cmux.json: the engine a browser tab uses when
/// it is created without an explicit engine (New Browser Tab, the "+" menu,
/// links from terminals, `cmux browser open`). Chromium unless set.
public nonisolated enum BrowserDefaultEngine: String, Sendable, Hashable, CaseIterable {
    case chromium
    case webkit

    public static let configPath = ["browser", "defaultEngine"]
    public static let fallback: BrowserDefaultEngine = .chromium

    /// Parses the `browser` section. A missing key is the default with no
    /// diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserDefaultEngine, SettingsDiagnostic?) {
        guard let browser = root["browser"] else { return (fallback, nil) }
        guard case .object(let members) = browser else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser", message: "expected an object"))
        }
        guard let value = members["defaultEngine"] else { return (fallback, nil) }
        guard let text = value.stringValue, let engine = BrowserDefaultEngine(rawValue: text) else {
            let choices = allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.defaultEngine", message: "expected \(choices)"))
        }
        return (engine, nil)
    }
}
