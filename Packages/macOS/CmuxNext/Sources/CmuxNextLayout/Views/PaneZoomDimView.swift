import AppKit
import CmuxNextDesign
import QuartzCore

/// The dim over the other panes of a screen around a zoom (``PaneZoomDim``). One view in the overlay plane, above
/// every pane's ring and above pages, below the drop highlight: one layer that carries the dim's opacity, with four
/// plain layers in it around the content rect of the pane that zooms (above, below, left, right). It has no mask and
/// no blur. The four layers are square, so the small areas outside the pane's rounded corners stay undimmed.
///
/// Its opacity changes while it shows, on the render server (`Motion.panes`, the pane veil's fade). At a zoom whose
/// pane moves, the four layers move too, so the hole goes with the pane (``moveHole(from:_:)``). It is in the plane
/// only around a zoom: a layout at rest carries no layer for it.
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = CGRect(origin: .zero, size: extent.size)
        for (part, rect) in zip(parts, Self.rects(around: hole.offsetBy(dx: -extent.minX, dy: -extent.minY), in: extent.size)) { part.frame = rect }
        CATransaction.commit()
    }

    /// The four parts around `hole` in a view of `size` (above, below, left, right), in the view's coordinates. Only
    /// what is inside the view is left clear: a pane with nothing of it in the screen leaves no hole.
    private static func rects(around hole: CGRect, in size: CGSize) -> [CGRect] {
        let shown = hole.intersection(CGRect(origin: .zero, size: size))
        let clear = shown.isNull ? .zero : shown
        return [CGRect(x: 0, y: 0, width: size.width, height: clear.minY),
                CGRect(x: 0, y: clear.maxY, width: size.width, height: size.height - clear.maxY),
                CGRect(x: 0, y: clear.minY, width: clear.minX, height: clear.height),
                CGRect(x: clear.maxX, y: clear.minY, width: size.width - clear.maxX, height: clear.height)]
    }

    /// The hole goes with a pane that moves to the place the dim was put around: it starts at `old` (the plane's
    /// coordinates). `move` gets each part with how far its origin is from its place at the start, and how much
    /// larger it is then; it puts that move on the part's layer.
    func moveHole(from old: CGRect, _ move: (CALayer, CGPoint, CGSize) -> Void) {
        for (part, from) in zip(parts, Self.rects(around: old.offsetBy(dx: -frame.minX, dy: -frame.minY), in: frame.size)) {
            let now = part.frame
            move(part, CGPoint(x: from.minX - now.minX, y: from.minY - now.minY), CGSize(width: from.width - now.width, height: from.height - now.height))
        }
    }

    /// The dim comes, on the pane veil's fade: from nothing to its full strength, or, `continuing` a dim that was
    /// going, from the strength it shows.
    func fadeIn(continuing: Bool) {
        Motion.panes.set(dim, "opacity", to: Float(amount), fade: .paneDim, from: continuing ? nil : Float(0))
    }

    /// The dim goes, on the pane veil's fade: from its full strength to nothing, or, `continuing` a dim that came
    /// with a zoom, from the strength it shows.
    func fadeOut(continuing: Bool) {
        Motion.panes.set(dim, "opacity", to: Float(0), fade: .paneDim, from: continuing ? nil : Float(amount))
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
