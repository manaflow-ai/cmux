import AppKit

/// A menu's separator: one hairline, ``MenuMetrics/separatorInset`` in from the menu's edges.
@MainActor
final class GlassMenuSeparatorView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = MenuMetrics.separatorInset - MenuMetrics.highlightInset
        let line = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        guard line > 0 else { return }
        performWithTheme {
            Palette.separator.setFill()
            NSRect(x: inset, y: (bounds.midY - line / 2), width: max(0, bounds.width - inset * 2), height: line).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
