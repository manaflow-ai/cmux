/// `browser.links` in cmux.json: what modified link clicks do in browser
/// tabs of both engines. Chrome's defaults, except Command-click, which opens
/// the link where `layout.linkPlacement` puts every link (`linkPlacement`:
/// by default the pane right of the page, else a new split there; user
/// 2026-10-20: "cmd click on links needs to always open in the right"):
///
/// ```jsonc
/// "browser": {
///   "links": {
///     "cmdClick": "linkPlacement",
///     "cmdShiftClick": "foregroundTab",
///     "shiftClick": "newWindow",
///     "optionClick": "download",
///     "middleClick": "backgroundTab"
///   }
/// }
/// ```
///
/// A plain click always loads the link in the current tab. A Shift-middle
/// click follows `cmdShiftClick`, as in Chrome. Each key's path and default come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserLinkClickSetting: Sendable, Hashable {
    public typealias Action = BrowserLinkClickAction

    public var cmdClick = BrowserLinkClickSetting.cmdClickDefault
    public var cmdShiftClick = BrowserLinkClickSetting.cmdShiftClickDefault
    public var shiftClick = BrowserLinkClickSetting.shiftClickDefault
    public var optionClick = BrowserLinkClickSetting.optionClickDefault
    public var middleClick = BrowserLinkClickSetting.middleClickDefault

    public init() {}

    public static let fallback = BrowserLinkClickSetting()
    public static let configPath = ["browser", "links"]

    /// Each key under `browser.links`, with its field.
    public static var keys: [(name: String, field: WritableKeyPath<BrowserLinkClickSetting, Action>)] { [
        ("cmdClick", \.cmdClick), ("cmdShiftClick", \.cmdShiftClick), ("shiftClick", \.shiftClick),
        ("optionClick", \.optionClick), ("middleClick", \.middleClick),
    ] }

    /// Missing keys are defaults with no diagnostic; a bad value is that
    /// key's default plus a diagnostic. Rust reads it (`link_rules.clicks`).
    static func parse(_ root: JSONValue) -> (BrowserLinkClickSetting, [SettingsDiagnostic]) {
        var setting = fallback
        let reply = SettingsRust.answer("link_rules.clicks", .object(["root": root]))
        for (name, field) in keys {
            if let action = reply["clicks"]?[name]?.stringValue.flatMap(Action.init(rawValue:)) {
                setting[keyPath: field] = action
            }
        }
        return (setting, LinkRouting.linkDiagnostics(reply))
    }
}

/// What one modified link click does (`browser.links.*`).
public nonisolated enum BrowserLinkClickAction: String, Sendable, Hashable, CaseIterable {
    case currentTab
    case backgroundTab
    case foregroundTab
    /// Where `layout.linkPlacement` puts every link (default: the pane
    /// right of the page's pane, or a new split there).
    case linkPlacement
    case newWindow
    case download
}
