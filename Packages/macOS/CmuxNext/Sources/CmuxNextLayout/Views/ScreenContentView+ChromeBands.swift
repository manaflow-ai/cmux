import CoreGraphics

// The tab bar bands each pane reports, for tab drop zones: a header on top
// and, with `tabs.barPosition` bottom (R109), a footer below.
extension ScreenContentView {
    func paneChromeBands() -> (headers: [PaneID: CGFloat], footers: [PaneID: CGFloat]) {
        var headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:]
        for pane in geometry.panes.keys {
            headers[pane] = context.hosts[pane]?.headerHeight
            footers[pane] = context.hosts[pane]?.footerHeight
        }
        return (headers, footers)
    }

    /// The dock bands start past the tab bar of the pane under the
    /// pointer: below its header, above its footer.
    func dockInsets(at point: CGPoint) -> (top: CGFloat, bottom: CGFloat) {
        guard let host = pane(at: point).flatMap({ context.hosts[$0] }) else { return (0, 0) }
        return (host.headerHeight, host.footerHeight)
    }
}
