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
    public func update(card: CGRect, radius: CGFloat, alpha: CGFloat) {
        guard card != self.card || radius != self.radius || alpha != self.alpha || shade.frame != bounds || Metrics.floatingPanes else { return }
        self.card = card
        self.radius = radius
        self.alpha = alpha
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
            // The card clips its panes: one held at another width through a sidebar slide
            // (`MainPaneCardView.contentHold`) cuts no shade past the card's edge.
            let corner = min(radius, card.width / 2, card.height / 2)
            let visible = cut.intersection(CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil))
            shade.path = CGPath(rect: bounds, transform: nil).subtracting(visible)
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
