public import Foundation

/// Everything an engine needs to create a page for a browser panel.
public struct BrowserPageConfiguration: Equatable, Sendable {
    /// The browser panel that hosts the page.
    public var panelID: UUID
    /// The browser profile whose website data the page uses.
    public var profileID: UUID
    /// Loaded right after creation; `nil` leaves the page blank.
    public var initialURL: URL?
    /// Starting page zoom, `1` is 100%.
    public var zoom: Double
    /// History to restore instead of loading ``initialURL`` fresh. Engines
    /// that cannot read the state load ``initialURL``.
    public var restoreState: BrowserPageRestoreState?
    /// A user agent that replaces the engine default, or `nil`.
    public var customUserAgent: String?

    /// Creates a page configuration.
    /// - Parameters:
    ///   - panelID: The hosting panel.
    ///   - profileID: The browser profile.
    ///   - initialURL: The first page to load, or `nil` for a blank page.
    ///   - zoom: Starting page zoom; defaults to 100%.
    ///   - restoreState: History to restore, or `nil`.
    ///   - customUserAgent: A user agent override, or `nil` for the engine default.
    public init(
        panelID: UUID,
        profileID: UUID,
        initialURL: URL? = nil,
        zoom: Double = 1,
        restoreState: BrowserPageRestoreState? = nil,
        customUserAgent: String? = nil
    ) {
        self.panelID = panelID
        self.profileID = profileID
        self.initialURL = initialURL
        self.zoom = zoom
        self.restoreState = restoreState
        self.customUserAgent = customUserAgent
    }
}
