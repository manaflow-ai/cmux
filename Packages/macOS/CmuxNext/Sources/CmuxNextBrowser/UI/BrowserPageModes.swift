public import Observation
import Foundation

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
    /// The document design mode belongs to, kept while another tab of the pane shows: a page that navigated meanwhile
    /// shows again with design mode off (`BrowserToolbarButtonsView.bind(_:modes:)`).
    @ObservationIgnored var pageURL: URL?

    public init() {}
}
