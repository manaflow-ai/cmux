enum FeedPlacement: Equatable, Sendable {
    case rightSidebar
    case pane

    var usesRightSidebarFocusCoordinator: Bool {
        self == .rightSidebar
    }
}
