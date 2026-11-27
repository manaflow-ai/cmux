/// `browser.import.cookieBanner` in cmux.json: whether the person's browser
/// tabs offer to import cookies from their other browsers (a card at the
/// bottom of the page, once per launch). On by default. Don't Show Again on
/// the card writes `false` here, so the dismissal lasts across launches and
/// shows in Settings; turning it on again brings the card back. The card
/// never imports by itself, and `browser.import.enabled` off hides it too.
///
/// `configPath` and `fallback` come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserCookieBannerSetting: Sendable {
    public init() {}
}
