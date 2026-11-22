import AppKit
import CmuxNextDesign
import QuartzCore

extension PaneHostView {
    /// The corners of `rect` (this host's coordinates, the area the ring traces) that
    /// meet a rounded clip around the pane, and the radius concentric with that clip.
    ///
    /// The clips are the chrome style's own corners, read where they are drawn, so no
    /// second table of radii can drift from them: every ancestor whose layer clips with a
    /// corner radius (the curved main pane, `Metrics.mainPaneCornerRadius`) and the
    /// window's own corners (`NSWindow.frameCornerRadius`). A corner inset from a clip's
    /// corner by `dx` and `dy` rounds with that clip's radius less the larger inset, so its
    /// curve runs parallel inside the clip's; a corner as far from it as the radius stays
    /// square. Where two clips meet one corner the larger radius wins: the ring must clear both.
    func clipCorners(of rect: CGRect) -> PaneOverlayView.ClipCorners {
        var result = PaneOverlayView.ClipCorners()
        var ancestor = superview
        while let view = ancestor {
            if let layer = view.layer, layer.masksToBounds, layer.cornerRadius > 0 {
                result.add(area: convert(rect, to: view), in: view.bounds, flipped: view.isFlipped, radius: layer.cornerRadius)
            }
            ancestor = view.superview
        }
        if let window, window.frameCornerRadius > 0 {
            result.add(area: convert(rect, to: nil), in: CGRect(origin: .zero, size: window.frame.size), flipped: false,
                       radius: window.frameCornerRadius)
        }
        return result
    }
}

private extension PaneOverlayView.ClipCorners {
    /// Adds the corners of `area` that meet the corners of a clip `bounds` rounded with `radius` (both in the clip's
    /// coordinates, `flipped` when its y runs down). The ring's overlay is flipped: its top corners are the MinY ones.
    mutating func add(area: CGRect, in bounds: CGRect, flipped: Bool, radius clipRadius: CGFloat) {
        let leading = area.minX - bounds.minX, trailing = bounds.maxX - area.maxX
        let (top, bottom) = flipped ? (area.minY - bounds.minY, bounds.maxY - area.maxY) : (bounds.maxY - area.maxY, area.minY - bounds.minY)
        for (dx, dy, corner) in [(leading, top, CACornerMask.layerMinXMinYCorner), (trailing, top, .layerMaxXMinYCorner),
                                 (leading, bottom, .layerMinXMaxYCorner), (trailing, bottom, .layerMaxXMaxYCorner)] {
            let concentric = clipRadius - max(0, dx, dy)
            guard concentric >= 0.5 else { continue }
            corners.insert(corner)
            radius = max(radius, concentric)
        }
    }
}
