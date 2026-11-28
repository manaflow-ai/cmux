public import AppKit

/// A menu's separator: one hairline, ``MenuMetrics/separatorInset`` in from the menu's edges, in a
/// row ``MenuMetrics/separatorHeight`` high, in the menu look's share of the separator ink (none
/// draws only the gap). A ``GlassMenu``'s rows use it, and a cmux-drawn popover's on the menu grid,
/// such as Page Info.
@MainActor
public final class GlassMenuSeparatorView: NSView {
    /// The row inset the separator's frame starts at (the menu look's highlight inset).
    private let rowInset: CGFloat
    private let inkShare: CGFloat

    public init(inset: CGFloat = MenuMetrics.highlightInset, inkShare: CGFloat = 1) {
        rowInset = inset
        self.inkShare = inkShare
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.separatorHeight) }

    public override func draw(_ dirtyRect: NSRect) {
        let inset = MenuMetrics.separatorInset - rowInset
        let line = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        guard line > 0, inkShare > 0 else { return }
        performWithTheme {
            let ink = Palette.separator
            ink.withAlphaComponent(ink.alphaComponent * inkShare).setFill()
            NSRect(x: inset, y: (bounds.midY - line / 2), width: max(0, bounds.width - inset * 2), height: line).fill()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
