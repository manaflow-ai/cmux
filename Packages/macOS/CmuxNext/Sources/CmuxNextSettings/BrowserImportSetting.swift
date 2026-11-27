/// `browser.import.enabled` in cmux.json: on by default, so cmux offers to bring
/// data over from other browsers as it does today. Off, cmux's Import from
/// Browser entry points leave (the menu items and palette actions, the import
/// tool window, the browser tab's import offer, the import suggestion cards in
/// Settings) and nothing imports by itself: Keep in Sync stops
/// re-reading the other browser's history and a paused card job does not resume.
/// Data already imported stays. `configPath` and `fallback` come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated enum BrowserImportSetting {
}
