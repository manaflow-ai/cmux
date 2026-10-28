public import AppKit

/// Where the window root places the main pane (its content host) and the standard titlebar: a pure
/// function of the root's bounds, the sidebar's frame and the window's metrics.
/// `WindowRootView.layout()` sets these frames once per pass, as Chrome's
/// `BrowserViewLayout::Layout` frames the browser window's children from its bounds
/// (chrome/browser/ui/views/frame/browser_view_layout.cc), with no constraint solve per frame.
///
/// The root is not flipped: y grows upward, the titlebar sits at the top edge.
public struct WindowRootLayout: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        /// The root's bounds.
        public var bounds: CGRect
        /// The sidebar's frame in the root, its width mid-slide included (0 wide while hidden).
        public var sidebarFrame: CGRect
        /// The edge the sidebar sits on (`sidebar.side`, R109).
        public var side: SidebarSide
        /// `sidebar.style` = rail: the content and the title sit this far from the sidebar's window
        /// edge (`SidebarModel.contentInset`), so the rail's full sidebar opens over them; nil: they
        /// sit beside the sidebar's frame.
        public var railInset: CGFloat?
        /// The main pane's gutter on every side (`Metrics.mainPaneGutter`).
        public var gutter: CGFloat
        /// The main pane's gap under the titlebar (`WindowTitlebar.cardTopInset`).
        public var cardTopInset: CGFloat
        /// The standard titlebar's height; 0 with the minimal titlebar.
        public var titlebarHeight: CGFloat
        /// The right sidebar's on-screen width, on the edge opposite the sidebar; 0 while hidden.
        public var rightPanelWidth: CGFloat
        /// The title never starts nearer the window's leading edge than this (the traffic lights).
        public var trafficLightInset: CGFloat

        public init(bounds: CGRect, sidebarFrame: CGRect, side: SidebarSide, railInset: CGFloat?, gutter: CGFloat,
                    cardTopInset: CGFloat, titlebarHeight: CGFloat, rightPanelWidth: CGFloat, trafficLightInset: CGFloat) {
            self.bounds = bounds
            self.sidebarFrame = sidebarFrame
            self.side = side
            self.railInset = railInset
            self.gutter = gutter
            self.cardTopInset = cardTopInset
            self.titlebarHeight = titlebarHeight
            self.rightPanelWidth = rightPanelWidth
            self.trafficLightInset = trafficLightInset
        }
    }

    /// The content host (the curved main pane).
    public let content: CGRect
    /// The standard titlebar strip (0 high with the minimal titlebar).
    public let titlebar: CGRect

    public init(_ input: Input) {
        let bounds = input.bounds, gutter = input.gutter, panel = max(0, input.rightPanelWidth)
        let left = input.side == .left
        // The sidebar's inner edge, the one facing the content. A hidden sidebar is 0 wide at the window
        // edge, so the content keeps the gutter there.
        let edge: CGFloat = switch (left, input.railInset) {
        case (true, let inset?): bounds.minX + inset
        case (true, nil): max(bounds.minX, input.sidebarFrame.maxX)
        case (false, let inset?): bounds.maxX - inset
        case (false, nil): min(bounds.maxX, input.sidebarFrame.minX)
        }
        let contentMinX = left ? edge + gutter : bounds.minX + gutter + panel
        let contentMaxX = left ? bounds.maxX - gutter - panel : edge - gutter
        let titleHeight = max(0, input.titlebarHeight)
        let contentTop = bounds.maxY - titleHeight - input.cardTopInset, contentBottom = bounds.minY + gutter
        content = CGRect(x: contentMinX, y: contentBottom, width: max(0, contentMaxX - contentMinX),
                         height: max(0, contentTop - contentBottom))
        // When the sidebar hides, the title stops clear of the traffic lights while the content below
        // reaches the window edge.
        let titleMinX = max(left ? edge : bounds.minX, bounds.minX + input.trafficLightInset)
        let titleMaxX = left ? bounds.maxX : edge
        titlebar = CGRect(x: titleMinX, y: bounds.maxY - titleHeight, width: max(0, titleMaxX - titleMinX), height: titleHeight)
    }
}
