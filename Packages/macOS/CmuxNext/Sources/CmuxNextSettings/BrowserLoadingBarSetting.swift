/// `browser.showLoadingBar` in cmux-next.json: the thin progress line under a
/// browser tab's address bar while a page loads. Off by default (user,
/// 2026-11-10): the Stop button is the loading cue. `configPath` and `fallback`
/// come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserLoadingBarSetting: Sendable {
    /// Creates the `browser.showLoadingBar` setting.
    public init() {}
}
