import CmuxProductAnalytics

extension RightSidebarMode {
    /// The feature this right-sidebar tab counts as in product analytics.
    var productFeature: ProductFeature {
        switch self {
        case .files: .filesExplorer
        case .find: .find
        case .sessions: .vault
        case .feed: .feed
        case .dock: .dock
        case .machines: .cloudSidebar
        case .customSidebar: .customSidebar
        }
    }
}
