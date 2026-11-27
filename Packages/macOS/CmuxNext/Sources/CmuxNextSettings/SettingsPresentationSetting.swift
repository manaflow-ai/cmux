/// `window.settingsPresentation` in cmux-next.json: where Settings opens. `tab` (the default) is an
/// internal page tab in the active pane; `page` is the window's top page, the whole window with the
/// category sidebar on the left, as the reference desktop agent apps draw their settings (a look
/// turns it on: customize-app-profiles, the settings surface).
///
/// Read from the snapshot's document, not stored: only the literal `"page"` turns it on, so a
/// missing or unknown value keeps the tab.
public nonisolated struct SettingsPresentationSetting: Sendable {
    // `configPath`, `fallback` ("tab") and `values` are generated from schemas/settings/source/general.json.

    /// Makes the value from its parts.
    public init() {}

    /// Whether Settings opens as the window's top page in `root`.
    public func opensAsPage(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.stringValue == "page"
    }
}
