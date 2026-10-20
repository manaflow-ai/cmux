/// A section that re-reads its window's state each time it shows (the window
/// may show another workspace since).
@MainActor
protocol RightSidebarRefreshing: AnyObject {
    func refresh()
}
