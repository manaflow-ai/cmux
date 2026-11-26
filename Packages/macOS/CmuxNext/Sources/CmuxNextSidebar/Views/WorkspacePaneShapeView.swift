import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The hover card's miniature of a workspace's splits (``SidebarPaneShape``): one rounded tile per pane at its
/// real share of the screen, the pane's front tab's mark in it, the focused pane outlined in the accent.
/// Leo 2026-11-22 (ask-890db939a2): "i have this layout. so. the preview should be able to depict that."
final class WorkspacePaneShapeView: NSView {
    /// The miniature's height; its width is the card's text column.
    static let height: CGFloat = 64
    static let gap: CGFloat = 3
    static let cornerRadius: CGFloat = 4
    static let markSize: CGFloat = 12

    var shape: SidebarPaneShape? {
        didSet {
            guard shape != oldValue else { return }
            isHidden = shape == nil
            needsDisplay = true
            setAccessibilityLabel(shape.map { Self.accessibilityText($0) })
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("cmux.sidebar.hoverCard.paneShape")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let shape else { return }
        performWithTheme {
            let fill = Palette.textPrimary.withAlphaComponent(0.07)
            let edge = Palette.textPrimary.withAlphaComponent(0.16)
            let focus = Palette.accent
            let markTint = Palette.textSecondary.cgColor
            for (frame, pane) in shape.frames(in: bounds.insetBy(dx: 0.5, dy: 0.5), gap: Self.gap) {
                let path = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
                fill.setFill()
                path.fill()
                (pane.focused ? focus : edge).setStroke()
                path.lineWidth = pane.focused ? 1.5 : 1
                path.stroke()
                // A mark only where it fits with room around it, so a sliver of a pane reads as a pane, not a glyph.
                guard let kind = pane.kind, frame.width >= Self.markSize * 2, frame.height >= Self.markSize * 2,
                      let image = CGImage.icon(kind.iconName, size: Self.markSize, scale: window?.backingScaleFactor ?? 2, tint: markTint),
                      let context = NSGraphicsContext.current?.cgContext else { continue }
                let mark = CGRect(x: frame.midX - Self.markSize / 2, y: frame.midY - Self.markSize / 2,
                                  width: Self.markSize, height: Self.markSize)
                context.saveGState()
                // The view is flipped; a CGImage draws bottom-up.
                context.translateBy(x: 0, y: mark.maxY + mark.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: mark)
                context.restoreGState()
            }
        }
    }

    func applyColors() { needsDisplay = true }

    /// "Panes: 3" for VoiceOver.
    static func accessibilityText(_ shape: SidebarPaneShape) -> String { Strings.paneCount(shape.paneCount) }
}
