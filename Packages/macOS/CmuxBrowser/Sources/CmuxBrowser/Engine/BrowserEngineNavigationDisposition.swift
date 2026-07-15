/// The cmux destination requested by an engine-originated browser navigation.
public enum BrowserEngineNavigationDisposition: Equatable, Sendable {
    /// Continue navigation in the current browser pane.
    case currentTab

    /// Route a new-window request into a cmux browser tab.
    case newTab
}
