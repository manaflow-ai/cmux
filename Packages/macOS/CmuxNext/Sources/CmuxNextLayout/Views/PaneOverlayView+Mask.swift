import AppKit
import CmuxNextDesign
import QuartzCore

/// The overlay's exclusion mask: the docked columns and the panes in front that hide a ring and a dim, at
/// rest and while the overlay rides its host's render-server spring (`PaneOverlayView+RenderSpring`).
extension PaneOverlayView {
    /// Hides the overlay inside `rects` (its own coordinates): a docked
    /// column covering this strip pane, a pane in front of it. Empty removes the mask.
    func setExcluded(_ rects: [CGRect]) {
        let rects = rects.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0.5 && $0.height > 0.5 }
        guard rects != excluded || (!rects.isEmpty && bounds != excludedBounds) else { return }
        excluded = rects
        excludedBounds = bounds
        placeMask()
    }

    /// The exclusion mask: this view's bounds (``maskRideOuter`` on a ride) minus the excluded rects. Its bounds
    /// are what it covers, so its coordinates are this view's and a ride moves it by its position alone.
    private func placeMask() {
        guard let layer else { return }
        guard !excluded.isEmpty else {
            layer.mask = nil
            return
        }
        let outer = maskRideOuter ?? bounds
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        // Subtracted, not even-odd: a docked column and a pane in front can overlap.
        let path = excluded.reduce(CGPath(rect: outer, transform: nil)) { $0.subtracting(CGPath(rect: $1, transform: nil)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .nonZero
        mask.bounds = outer
        mask.position = CGPoint(x: outer.midX, y: outer.midY)
        mask.path = path
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
    }

    /// The exclusion mask's springs while this overlay rides from `from` (the plane's coordinates, moving at
    /// `velocity`) to its frame now. The sync cut the covers out where they rest in the plane (every host at
    /// rest), so the mask moves against the overlay's own move and the cutouts stay there; and it covers the
    /// overlay's bounds at the start as well as at rest, so no ring or dim outside the rest rect is cut off.
    /// Empty without excluded rects; ``endMaskRide()`` puts the rest mask back.
    func rideMask(from: CGRect, velocity: RectComponents) -> [RenderSpring.Move] {
        guard !excluded.isEmpty, layer?.mask != nil else { return [] }
        let shift = CGPoint(x: from.minX - frame.minX, y: from.minY - frame.minY)
        maskRideOuter = (maskRideOuter ?? bounds).union(CGRect(origin: shift, size: from.size))
        placeMask()
        guard let mask = layer?.mask else { return [] }
        let rest = mask.position
        return [
            RenderSpring.Move(mask, .positionX, from: rest.x - shift.x, to: rest.x, velocity: -velocity.x),
            RenderSpring.Move(mask, .positionY, from: rest.y - shift.y, to: rest.y, velocity: -velocity.y),
        ]
    }

    /// The ride landed or went back to the CPU: the mask's springs stop and it covers the rest bounds again.
    func endMaskRide() {
        if let mask = layer?.mask { RenderSpring.stop(mask, "position") }
        guard maskRideOuter != nil else { return }
        maskRideOuter = nil
        placeMask()
    }
}
