/// `browser.import.cookieBanner` in cmux.json: whether the person's browser
/// tabs offer to import cookies from their other browsers (a card at the
/// bottom of the page, once per launch). On by default. Don't Show Again on
/// the card writes `false` here, so the dismissal lasts across launches and
/// shows in Settings; turning it on again brings the card back. The card
/// never imports by itself, and `browser.import.enabled` off hides it too.
public nonisolated struct BrowserCookieBannerSetting: Sendable {
    /// The key's path in cmux.json.
    public let configPath = ["browser", "import", "cookieBanner"]
    /// The value when the key is absent: offered.
    public let fallback = true

    /// The setting's path and default.
    public init() {}

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let shown = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "browser.import.cookieBanner", message: "expected true or false"))
        }
        return (shown, nil)
    }
}
