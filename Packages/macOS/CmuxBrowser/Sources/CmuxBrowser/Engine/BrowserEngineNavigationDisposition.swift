/// The destination requested by a browser-engine navigation.
public enum BrowserEngineNavigationDisposition: Equatable, Sendable {
    /// Continue in the current browser pane.
    case currentTab

    /// Route the request to a new cmux browser tab.
    case newTab
}
