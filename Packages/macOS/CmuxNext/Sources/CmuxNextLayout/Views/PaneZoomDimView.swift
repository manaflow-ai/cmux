import AppKit
import CmuxNextDesign
import QuartzCore

/// The dim over the other panes while a pane zooms or goes back (`PaneZoomMotion.dim`). One view in the
/// overlay plane, above every pane's ring and above pages, below the drop highlight: four plain layers
/// around the zooming pane's content rect (above, below, left, right), one opacity for all four. It has
/// no mask, no blur and no animation of its own: after each overlay sync of a zoom frame it takes the
/// value the zoom's spring has now (times `Palette.zoomDim`) and the pane's rect of that frame. The
/// four layers are square, so the small areas outside the pane's rounded corners stay undimmed.
///
/// It is in the plane only while a pane zooms: the sync of the frame the zoom lands in takes it out, so a
/// zoom at rest and a layout with no zoom draw nothing more and carry no layer for it.
final class PaneZoomDimView: NSView {
    static let dimIdentifier = NSUserInterfaceItemIdentifier("pane.zoom.dim")

    private let parts = [CALayer(), CALayer(), CALayer(), CALayer()]
    /// The opacity at a zoom's end (`Palette.zoomDim` in this view's theme), read with the colors.
    private var amount: CGFloat = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.dimIdentifier
        wantsLayer = true
        setAccessibilityElement(false)
        for part in parts { layer?.addSublayer(part) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A dim that follows `root`'s overlay syncs in `plane` for as long as the returned observation lives.
    static func follow(_ root: LayoutRootView, in plane: OverlayPlane) -> LayoutOverlaySyncObservation {
        let dim = PaneZoomDimView()
        return root.observeOverlaySync { [weak root, weak plane] in
            guard let root, let plane else { return }
            dim.sync(root, in: plane)
        }
    }

    /// Shows the dim of the shown screen whose pane zooms (the active screen first), or leaves the plane.
    private func sync(_ root: LayoutRootView, in plane: OverlayPlane) {
        var zooming: ScreenContentView?
        for screen in root.screenViews.values where !screen.isHidden && screen.zoomMotion.pane != nil {
            if zooming == nil || screen.screenID == root.model.activeScreenID { zooming = screen }
        }
        guard let screen = zooming, let pane = screen.zoomMotion.pane, let host = root.context.hosts[pane],
              host.superview === screen, screen.zoomMotion.dim.value > 0 else {
            if superview != nil { removeFromSuperview() }
            return
        }
        // Directly below the drop highlight: above each ring, also one that joined the plane after the dim.
        let siblings = plane.subviews
        if siblings.firstIndex(of: self).map({ $0 + 1 < siblings.count && siblings[$0 + 1] === root.highlight }) != true {
            plane.addSubview(self, positioned: .below, relativeTo: root.highlight)
            applyColors()
        }
        // The plane's items are in the root's coordinates; the layers are in this view's.
        let extent = root.convert(screen.bounds, from: screen)
        let shown = root.convert(host.contentRect, from: host).offsetBy(dx: -extent.minX, dy: -extent.minY)
            .intersection(CGRect(origin: .zero, size: extent.size))
        // A pane with nothing of it in the screen leaves no hole: the second layer takes the whole extent.
        let hole = shown.isNull ? .zero : shown
        if frame != extent { frame = extent }
        let opacity = amount * min(screen.zoomMotion.dim.value, 1)
        if alphaValue != opacity { alphaValue = opacity }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parts[0].frame = CGRect(x: 0, y: 0, width: extent.width, height: hole.minY)
        parts[1].frame = CGRect(x: 0, y: hole.maxY, width: extent.width, height: extent.height - hole.maxY)
        parts[2].frame = CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height)
        parts[3].frame = CGRect(x: hole.maxX, y: hole.minY, width: extent.width - hole.maxX, height: hole.height)
        CATransaction.commit()
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
