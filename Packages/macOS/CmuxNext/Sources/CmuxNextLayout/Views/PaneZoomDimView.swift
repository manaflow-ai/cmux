import AppKit
import CmuxNextDesign
import QuartzCore

/// The dim over the other panes of a screen around a zoom (``PaneZoomDim``). One view in the overlay plane, above
/// every pane's ring and above pages, below the drop highlight: one layer that carries the dim's opacity, with four
/// plain layers in it around the content rect of the pane that zooms (above, below, left, right). It has no mask and
/// no blur. The four layers are square, so the small areas outside the pane's rounded corners stay undimmed.
///
/// Its opacity is the only thing that changes while it shows, on the render server (`Motion.panes`, the pane veil's
/// fade): no pane moves under it. It is in the plane only around a zoom: a layout at rest carries no layer for it.
final class PaneZoomDimView: NSView {
    static let dimIdentifier = NSUserInterfaceItemIdentifier("pane.zoom.dim")

    /// Carries the dim's opacity; the four parts are its sublayers.
    private let dim = CALayer()
    private let parts = [CALayer(), CALayer(), CALayer(), CALayer()]
    /// The dim's full strength (`Palette.zoomDim` in this view's theme), read with the colors.
    private var amount: CGFloat = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.dimIdentifier
        wantsLayer = true
        setAccessibilityElement(false)
        dim.opacity = 0
        layer?.addSublayer(dim)
        for part in parts { dim.addSublayer(part) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puts the dim over `extent` less `hole` (the plane's coordinates), below `sibling` in `plane`.
    func place(in plane: NSView, below sibling: NSView, extent: CGRect, hole: CGRect) {
        if superview !== plane {
            plane.addSubview(self, positioned: .below, relativeTo: sibling)
            applyColors()
        }
        if frame != extent { frame = extent }
        // The hole in this view's coordinates, inside it. A pane with nothing of it in the screen leaves no hole.
        let shown = hole.offsetBy(dx: -extent.minX, dy: -extent.minY).intersection(CGRect(origin: .zero, size: extent.size))
        let clear = shown.isNull ? .zero : shown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = CGRect(origin: .zero, size: extent.size)
        parts[0].frame = CGRect(x: 0, y: 0, width: extent.width, height: clear.minY)
        parts[1].frame = CGRect(x: 0, y: clear.maxY, width: extent.width, height: extent.height - clear.maxY)
        parts[2].frame = CGRect(x: 0, y: clear.minY, width: clear.minX, height: clear.height)
        parts[3].frame = CGRect(x: clear.maxX, y: clear.minY, width: extent.width - clear.maxX, height: clear.height)
        CATransaction.commit()
    }

    /// The dim comes, on the pane veil's fade: from nothing to its full strength, or, `continuing` a dim that was
    /// going, from the strength it shows.
    func fadeIn(continuing: Bool) {
        Motion.panes.set(dim, "opacity", to: Float(amount), fade: .paneDim, from: continuing ? nil : Float(0))
    }

    /// The dim goes: from its full strength to nothing, on the pane veil's fade.
    func fadeOut() {
        Motion.panes.set(dim, "opacity", to: Float(0), fade: .paneDim, from: Float(amount))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The window's ground, opaque: the pane fill is clear in a glass window and would dim nothing there.
    private func applyColors() {
        performWithTheme {
            amount = Palette.zoomDim
            let color = Palette.surfaceBackground.withAlphaComponent(1).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for part in parts { part.backgroundColor = color }
            CATransaction.commit()
        }
    }
}
