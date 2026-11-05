public import AppKit

/// The shade over the chrome around the curved main pane: the window minus
/// the pane's rounded rect, filled with black at a low alpha. It sits on
/// the window's one backdrop, under the sidebar and the titlebar (both
/// clear), so they and the gutter read as chrome and the pane as a card,
/// over an opaque or a translucent window alike. Takes no clicks.
/// Floating panes (`Metrics.floatingPanes`): the shade leaves out each
/// pane's card (`paneCards`) instead of the main pane, so the sidebar, the
/// titlebar and every gap share the one darker color and the panes keep
/// the window's own surface (Ghostty background, art and opacity).
public final class MainPaneChromeShadeView: NSView {
    private let shade = CAShapeLayer()
    private var card: CGRect = .zero
    private var radius: CGFloat = 0
    private var alpha: CGFloat = 0
    /// Hard-edge chrome (`chrome.hardEdge`): the card's hole is chamfered, and its cut corners
    /// and marks are drawn above the content too (``hardEdgeFrame``).
    private var hardEdge: HardEdge = .off
    private var sidebarLeading = true
    private let hardEdgeFrame = HardEdgeFrameView(frame: .zero)
    private var cardsObservation: AnyObject?
    /// The shown workspace's pane cards; a sync of theirs reshapes the shade.
    public weak var paneCards: (any PaneCardSource)? {
        didSet {
            if paneCards !== oldValue {
                cardsObservation = paneCards?.observePaneCards { [weak self] in
                    if Metrics.floatingPanes { self?.rebuild() }
                }
            }
            rebuild()
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shade.fillRule = .evenOdd
        layer?.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The window resized (its autoresizing frame may land after the card's
    /// in the same pass): the path follows these bounds.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    /// Shades everything but `card` (this view's coordinates); no shade when
    /// `alpha` is 0.
    /// `hardEdge` on: the card is the part of `content` below its top tab strip (the strip sits on
    /// the frame with the sidebar), its hole is chamfered (cut toward the sidebar,
    /// `sidebarLeading`), and the cut corners and marks are drawn above `content` (``HardEdgeFrameView``).
    public func update(card content: CGRect, radius: CGFloat, alpha: CGFloat, hardEdge: HardEdge = .off, sidebarLeading: Bool = true,
                       content contentView: NSView? = nil) {
        var card = content
        if hardEdge.isOn, DesignSettings.shared.tabBarPosition != .bottom {
            card.size.height = max(0, card.height - (Metrics.stripTopOutset + Metrics.tabStripHeight)) // the top is maxY
        }
        hardEdgeFrame.update(card: card, alpha: alpha, style: hardEdge, sidebarLeading: sidebarLeading, above: contentView, in: superview)
        guard card != self.card || radius != self.radius || alpha != self.alpha || hardEdge != self.hardEdge
            || sidebarLeading != self.sidebarLeading || shade.frame != bounds || Metrics.floatingPanes else { return }
        self.card = card
        self.radius = radius
        self.alpha = alpha
        self.hardEdge = hardEdge
        self.sidebarLeading = sidebarLeading
        rebuild()
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shade.frame = bounds
        guard alpha > 0, !card.isEmpty else {
            shade.path = nil
            return
        }
        // Floating panes leave out each pane's card (content with no panes,
        // a top page, keeps the main pane's card), as one union so holes
        // that overlap mid-motion stay unshaded.
        if Metrics.floatingPanes, let paneCards {
            let cut = paneCards.paneCardsInWindow.reduce(CGMutablePath()) { union, card in
                let rect = convert(card.rect, from: nil), corner = min(card.radius, rect.width / 2, rect.height / 2)
                let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
                return (union.isEmpty ? path : union.union(path)).mutableCopy() ?? union
            }
            // The card clips its panes: one held wider than the card through a sidebar slide
            // (`MainPaneCardView.contentHold`) cuts no shade past the card's edge.
            let corner = min(radius, card.width / 2, card.height / 2)
            let visible = cut.intersection(CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil))
            shade.path = CGPath(rect: bounds, transform: nil).subtracting(visible)
        } else if hardEdge.isOn {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addPath(HardEdge.path(card, cuts: HardEdgeFrameView.cardCuts(sidebarLeading: sidebarLeading), flipped: false))
            shade.path = path
        } else {
            let path = CGMutablePath()
            path.addRect(bounds)
            let corner = min(radius, card.width / 2, card.height / 2)
            path.addRoundedRect(in: card, cornerWidth: corner, cornerHeight: corner)
            shade.path = path
        }
        shade.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }
}

/// One pane's card on the window: its rect in window coordinates and its
/// corner radius (`MainPaneChromeShadeView.paneCards`).
public nonisolated struct PaneCard: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat

    public init(rect: CGRect, radius: CGFloat) {
        self.rect = rect
        self.radius = radius
    }
}

/// What shows the panes of a window's workspace (the layout root): their
/// cards as displayed now, and a callback whenever they move.
@MainActor
public protocol PaneCardSource: AnyObject {
    var paneCardsInWindow: [PaneCard] { get }
    /// Calls `block` after the panes moved; lives as long as the result.
    func observePaneCards(_ block: @escaping () -> Void) -> AnyObject
}
