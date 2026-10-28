public import Observation

/// Per-tab page modes the toolbar shows: design mode (classic's highlight
/// runtime, `BrowserDesignModeScript`)
/// and the forced color scheme. The App's actions write them; the chrome's
/// toolbar buttons observe them.
@Observable
public final class BrowserPageModes {
    /// Whether design mode is on. A new document starts with it off, so
    /// the toolbar clears it when the page URL changes.
    public var designMode = false
    /// The color scheme forced on the page; `.system` follows the app.
    public var colorScheme: BrowserColorScheme = .system

    public init() {}
}
