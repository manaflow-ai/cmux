public import AppKit

/// A table row whose selection is the theme's selection fill, never the system accent (cx-wqn5):
/// selected rows in dialogs and lists read like the sidebar's and the palette's. Never emphasized,
/// so the row's text keeps its own color instead of turning white on blue.
public final class ThemedTableRowView: NSTableRowView {
    public override var isEmphasized: Bool {
        get { false }
        set {}
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Metrics.space1, dy: 1)
        Palette.selectionFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
    }
}

extension NSButton {
    /// The Return (default) button in the theme's selection fill instead of the system accent.
    public func useThemeDefaultBezel() {
        bezelColor = Palette.selectionFill
    }
}
