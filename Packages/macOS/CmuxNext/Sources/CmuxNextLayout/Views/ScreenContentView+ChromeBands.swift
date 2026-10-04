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
}
