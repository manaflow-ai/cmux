import AppKit
import CmuxNextDesign
import QuartzCore

/// The layer under an overlay docked column (dock-column.md, V2): a
/// Liquid Glass rim (`OverlaySurfaceView`, so Reduce Transparency gets the
/// opaque fill) around the column, a subtle shadow on the strip below,
/// and an opaque Ghostty-background fill behind the panes so glass never
/// sits behind terminal text and strip content never shows through a
/// translucent pane. Takes no mouse.
final class DockBackdropView: NSView {
    private let shadowView = NSView()
    private let surface = OverlaySurfaceView()
    private let fill = CALayer()
    private let rimMask = CAShapeLayer()
    private var column: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shadowView.wantsLayer = true
        addSubview(shadowView)
        addSubview(surface)
        surface.layer?.mask = rimMask
        rimMask.fillRule = .evenOdd
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `cover` is the backdrop's frame in the superview; `column` the
    /// docked column inside it (superview coordinates).
    func place(cover: CGRect, column: CGRect, paneCornerRadius: CGFloat) {
        if frame != cover { frame = cover }
        let inner = column.offsetBy(dx: -cover.minX, dy: -cover.minY)
        let rim = max(0, (cover.width - column.width) / 2)
        let outerRadius = paneCornerRadius + rim
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView.frame = bounds
        surface.frame = bounds
        surface.cornerRadius = outerRadius
        let outer = CGPath(roundedRect: bounds, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        let path = CGMutablePath()
        path.addPath(outer)
        path.addPath(CGPath(roundedRect: inner, cornerWidth: paneCornerRadius, cornerHeight: paneCornerRadius, transform: nil))
        rimMask.frame = bounds
        rimMask.path = path
        fill.frame = inner
        fill.cornerRadius = paneCornerRadius
        if let layer = shadowView.layer {
            layer.shadowPath = outer
            layer.shadowOpacity = 1
            layer.shadowRadius = Metrics.space5
            layer.shadowOffset = .zero
        }
        CATransaction.commit()
        self.column = column
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            // Opaque: the user's docks background laid over it (R55).
            fill.backgroundColor = Palette.opaqueFill(for: .docks, base: Palette.windowBackground.withAlphaComponent(1)).cgColor
            shadowView.layer?.shadowColor = Palette.shadow.cgColor
        }
        surface.applyTheme()
    }
}
