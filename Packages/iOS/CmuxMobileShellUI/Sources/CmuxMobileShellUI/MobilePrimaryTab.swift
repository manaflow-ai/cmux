#if os(iOS)
/// The mobile app's primary destinations and transient search selection.
enum MobilePrimaryTab: Hashable {
    /// Messages-style conversation home. It is only mounted when the
    /// selected Mac advertises the Chief mobile surface.
    case home
    case workspaces
    case feed
    case notifications
    case cloud
    case search

    /// The SF Symbol shared by the tab bar, the phone split sidebar's
    /// destination bar, and the detail bar's destination menu.
    var symbolName: String {
        switch self {
        case .home: "bubble.left.and.bubble.right"
        case .workspaces: "rectangle.stack"
        case .feed: "waveform"
        case .notifications: "bell"
        case .cloud: "cloud"
        case .search: "magnifyingglass"
        }
    }
}
#endif
