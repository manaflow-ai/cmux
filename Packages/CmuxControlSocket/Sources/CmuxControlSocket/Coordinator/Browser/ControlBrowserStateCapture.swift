/// The app-captured pieces of a `browser.state.save`: everything the legacy
/// body read in one resolved-panel pass (so mid-pump state changes cannot
/// split the capture).
public struct ControlBrowserStateCapture: Sendable, Equatable {
    /// The resolved workspace/surface identity.
    public let identity: ControlBrowserPanelIdentity
    /// The normalized local/session storage readout.
    public let storage: JSONValue
    /// The panel's cookies (empty when the store read timed out, as legacy).
    public let cookies: [ControlBrowserCookie]
    /// The panel's current URL (empty string when none, as legacy).
    public let url: String
    /// The surface's active frame selector, if any.
    public let frameSelector: String?

    /// Creates a state capture.
    ///
    /// - Parameters:
    ///   - identity: The resolved identity.
    ///   - storage: The normalized storage readout.
    ///   - cookies: The panel's cookies.
    ///   - url: The panel's current URL.
    ///   - frameSelector: The surface's active frame selector, if any.
    public init(
        identity: ControlBrowserPanelIdentity,
        storage: JSONValue,
        cookies: [ControlBrowserCookie],
        url: String,
        frameSelector: String?
    ) {
        self.identity = identity
        self.storage = storage
        self.cookies = cookies
        self.url = url
        self.frameSelector = frameSelector
    }
}
