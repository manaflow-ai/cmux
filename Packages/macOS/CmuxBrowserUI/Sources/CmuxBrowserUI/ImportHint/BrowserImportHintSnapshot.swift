/// Pure value snapshot driving the browser-data import-hint body (the title,
/// summary, settings footnote, and the three button labels).
///
/// Every field is already resolved app-side: the summary comes from the
/// installed-browser detector's `summaryText(for:)`, and all `String(localized:)`
/// titles/labels bind to the app bundle, so localization stays app-side and the
/// resolved strings are passed through here. Holding only `Sendable` values keeps
/// the import-hint and empty-state views renderable in this package without
/// reaching back into the app target.
public struct BrowserImportHintSnapshot: Sendable {
    /// Section title shown at the top of the hint body.
    public var title: String
    /// One-line summary of the detected browsers available to import.
    public var summary: String
    /// Footnote reminding the user the import lives in Settings > Browser.
    public var settingsFootnote: String
    /// Pre-localized label for the primary import button.
    public var primaryButtonTitle: String
    /// Pre-localized label for the open-browser-settings button.
    public var settingsButtonTitle: String
    /// Pre-localized label for the dismiss/hide-hint button.
    public var dismissButtonTitle: String

    /// Creates the import-hint snapshot from values already resolved app-side.
    public init(
        title: String,
        summary: String,
        settingsFootnote: String,
        primaryButtonTitle: String,
        settingsButtonTitle: String,
        dismissButtonTitle: String
    ) {
        self.title = title
        self.summary = summary
        self.settingsFootnote = settingsFootnote
        self.primaryButtonTitle = primaryButtonTitle
        self.settingsButtonTitle = settingsButtonTitle
        self.dismissButtonTitle = dismissButtonTitle
    }
}
