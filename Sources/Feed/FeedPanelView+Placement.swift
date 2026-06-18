extension FeedPanelView {
    enum Placement {
        case rightSidebar
        case pane

        var registersWithKeyboardFocusCoordinator: Bool {
            switch self {
            case .rightSidebar:
                return true
            case .pane:
                return false
            }
        }
    }
}
