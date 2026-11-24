public import AppKit

/// A menu's separator: one hairline, ``MenuMetrics/separatorInset`` in from the menu's edges, in a
/// row ``MenuMetrics/separatorHeight`` high laid ``MenuMetrics/highlightInset`` in from them (a
/// ``GlassMenu``'s rows, and a cmux-drawn popover's on the menu grid, such as Page Info).
@MainActor
public final class GlassMenuSeparatorView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.separatorHeight) }

    public override func draw(_ dirtyRect: NSRect) {
        let inset = MenuMetrics.separatorInset - MenuMetrics.highlightInset
        let line = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        guard line > 0 else { return }
        performWithTheme {
            Palette.separator.setFill()
            NSRect(x: inset, y: (bounds.midY - line / 2), width: max(0, bounds.width - inset * 2), height: line).fill()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
