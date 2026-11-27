/// A section that re-reads its window's state each time it shows (the window
/// may show another workspace since). The right sidebar that showed sections
/// is gone; the kept sections still conform.
@MainActor
protocol RightSidebarRefreshing: AnyObject {
    func refresh()
}
