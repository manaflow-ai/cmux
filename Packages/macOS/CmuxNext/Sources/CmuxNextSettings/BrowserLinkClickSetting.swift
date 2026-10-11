/// `browser.links` in cmux.json: what modified link clicks do in browser
/// tabs of both engines. Chrome's defaults:
///
/// ```jsonc
/// "browser": {
///   "links": {
///     "cmdClick": "backgroundTab",
///     "cmdShiftClick": "foregroundTab",
///     "shiftClick": "newWindow",
///     "optionClick": "download",
///     "middleClick": "backgroundTab"
///   }
/// }
/// ```
///
/// A plain click always loads the link in the current tab. A Shift-middle
/// click follows `cmdShiftClick`, as in Chrome.
public nonisolated struct BrowserLinkClickSetting: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable, CaseIterable {
        case currentTab
        case backgroundTab
        case foregroundTab
        case newWindow
        case download
    }

    public var cmdClick: Action = .backgroundTab
    public var cmdShiftClick: Action = .foregroundTab
    public var shiftClick: Action = .newWindow
    public var optionClick: Action = .download
    public var middleClick: Action = .backgroundTab

    public init() {}

    public static let fallback = BrowserLinkClickSetting()
    public static let configPath = ["browser", "links"]

    /// Each key under `browser.links`, with its field.
    public static var keys: [(name: String, field: WritableKeyPath<BrowserLinkClickSetting, Action>)] { [
        ("cmdClick", \.cmdClick), ("cmdShiftClick", \.cmdShiftClick), ("shiftClick", \.shiftClick),
        ("optionClick", \.optionClick), ("middleClick", \.middleClick),
    ] }

    /// Missing keys are defaults with no diagnostic; a bad value is that
    /// key's default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserLinkClickSetting, [SettingsDiagnostic]) {
        var setting = fallback
        guard let links = root.value(at: configPath) else { return (setting, []) }
        guard case .object(let members) = links else {
            return (setting, [SettingsDiagnostic(kind: .invalidValue, path: "browser.links", message: "expected an object")])
        }
        let choices = Action.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        var diagnostics: [SettingsDiagnostic] = []
        for (name, field) in keys {
            guard let value = members[name] else { continue }
            if let text = value.stringValue, let action = Action(rawValue: text) {
                setting[keyPath: field] = action
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.links.\(name)", message: "expected one of \(choices)"))
            }
        }
        return (setting, diagnostics)
    }
}
