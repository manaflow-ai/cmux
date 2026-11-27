/// `browser.vimKeys` in cmux.json: the single-letter page keys of a browser
/// tab outside a text field (`f` and `F` link hints, `j` and `k` scroll, `gg`
/// and `G` top and bottom). On by default; off, the page gets those letters
/// and the actions still run from the Command Palette. `configPath` and
/// `fallback` come from schemas/settings/source/browser.json
/// (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserVimKeysSetting: Sendable {
    /// Creates the `browser.vimKeys` setting.
    public init() {}
}
