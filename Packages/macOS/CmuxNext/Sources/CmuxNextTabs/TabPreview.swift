public import CoreGraphics

/// Supplies hover-card thumbnails. The App implements it with a snapshot of
/// the terminal or web view; the demo draws fake content.
public protocol TabPreviewProvider: AnyObject {
    /// A thumbnail for `tab`, at most `maxPixelSize`. Nil shows a placeholder.
    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage?
}

/// Chrome-like timing for the hover card.
public struct HoverCardPolicy: Equatable, Sendable {
    /// Delay over the narrowest tabs, where the card is the only way to read the title.
    public var minimumDelay: Duration = .milliseconds(300)
    /// Delay over full-width tabs, where the title is already readable.
    public var maximumDelay: Duration = .milliseconds(800)
    /// After a card hides, a new hover within this window shows immediately.
    public var reshowWindow: Duration = .milliseconds(700)

    public init() {}

    /// Delay before showing a card over a tab of `tabWidth`.
    public func showDelay(tabWidth: CGFloat, metrics: TabStripMetrics = .standard) -> Duration {
        let low = metrics.minInactiveTabWidth
        let high = metrics.maxTabWidth
        let fraction = high > low ? min(max((tabWidth - low) / (high - low), 0), 1) : 1
        let span = maximumDelay - minimumDelay
        return minimumDelay + span * Double(fraction)
    }

    /// Delay for a hover given the card state. Zero while a card is visible
    /// (moving across tabs updates it at once) or shortly after one hid.
    public func delay(
        tabWidth: CGFloat,
        cardIsVisible: Bool,
        sinceLastHidden: Duration?,
        metrics: TabStripMetrics = .standard
    ) -> Duration {
        if cardIsVisible { return .zero }
        if let sinceLastHidden, sinceLastHidden < reshowWindow { return .zero }
        return showDelay(tabWidth: tabWidth, metrics: metrics)
    }
}
