public import Observation

/// Per-tab page modes the toolbar shows: design mode (`document.designMode`)
/// and the forced color scheme. The App's actions write them; the chrome's
/// toolbar buttons observe them.
@Observable
public final class BrowserPageModes {
    /// Whether the page is editable. A new document starts with it off, so
    /// the toolbar clears it when the page URL changes.
    public var designMode = false
    /// The color scheme forced on the page; `.system` follows the app.
    public var colorScheme: BrowserColorScheme = .system

    public init() {}
}
