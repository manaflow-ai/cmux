public import AppKit

/// The shade over the chrome around the curved main pane: the window minus
/// the pane's rounded rect, filled with black at a low alpha. It sits on
/// the window's one backdrop, under the sidebar and the titlebar (both
/// clear), so they and the gutter read as chrome and the pane as a card,
/// over an opaque or a translucent window alike. Takes no clicks.
public final class MainPaneChromeShadeView: NSView {
    private let shade = CAShapeLayer()
    private var card: CGRect = .zero
    private var radius: CGFloat = 0
    private var alpha: CGFloat = 0

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
        guard card != self.card || radius != self.radius || alpha != self.alpha || shade.frame != bounds else { return }
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
        let path = CGMutablePath()
        path.addRect(bounds)
        let corner = min(radius, card.width / 2, card.height / 2)
        path.addRoundedRect(in: card, cornerWidth: corner, cornerHeight: corner)
        shade.path = path
        shade.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }
}
