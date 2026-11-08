#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// ZOOM VARIANTS film selector (``FilmZoomVariant``; DEBUG and bench builds only, branch zoom-variants/film-selector-nomerge,
/// never merged). Z1, Z2 and Z3 snap a zoom to its final frames (`reconcile`): one resize per terminal, its final grid sent
/// in the key's turn, the old picture held one tick (`ScreenContentView+SnapFrame`). Z2 and Z3 then play a motion on
/// copies of the panes' last pictures (their layer trees' contents: a terminal's last frame, the tab strip; a Chromium
/// page's own window is not in them), started by the presentation that shows the final layout:
/// - Z2 in: the other panes' pictures over the zoomed pane, with a hole that grows from its old frame to the full screen.
/// - Z2 out: the zoomed pane's old full picture over the final layout, its frame shrinking to the pane's place.
/// - Z3 in: the other panes' pictures over the zoomed pane slide out to the screen edges and fade.
/// - Z3 out: the other panes slide in from the screen edges and fade in over the zoomed pane's old full picture.
extension ScreenContentView {
    func prepareFilmZoom(_ film: FilmZoomVariant, zooming: Bool, before: ScreenGeometry, after: ScreenGeometry) {
        frameInput.filmZoomPending = nil
        layer?.sublayers?.filter { $0.name?.hasPrefix("film-zoom-pictures-") == true }.forEach { $0.removeFromSuperlayer() }
        guard film.kind != .z1, Motion.panes.animatesMovement, let root = layer else { return }
        let zoomed = zooming ? after.panes.keys.first : before.panes.keys.first { after.panes[$0] != nil }
        guard let zoomed, let zoomedHost = context.hosts[zoomed] else { return }
        let oldZoomedFrame = zoomedHost.frame
        let bounds = self.bounds
        // The pictures to copy now, before the hosts take their new frames: the other panes going in, the zoomed one out.
        var pictures: [(pane: PaneID, layer: CALayer, frame: CGRect)] = []
        if zooming {
            for (pane, host) in context.hosts where pane != zoomed && host.superview === self && before.panes[pane] != nil {
                guard let source = host.layer, host.frame.width >= 1, host.frame.height >= 1 else { continue }
                pictures.append((pane, Self.filmZoomCopy(source), host.frame))
            }
        } else if let source = zoomedHost.layer, oldZoomedFrame.width >= 1 {
            pictures.append((zoomed, Self.filmZoomCopy(source), oldZoomedFrame))
        }
        guard !pictures.isEmpty else { return }
        // The copies go on the root now, hidden, and show with the presentation of the final layout. The pending closure
        // finds them by name (no layer captured in it: it is main-actor code stored on the frame input).
        let tag = "film-zoom-pictures-\(UInt64.random(in: 0 ... UInt64.max))"
        let frames = pictures.map(\.frame)
        let container = CALayer()
        container.frame = bounds
        container.bounds = bounds // the view's coordinates inside it, as the hosts' frames are
        container.name = tag
        container.isHidden = true
        container.zPosition = film.kind == .z3 && !zooming ? -1 : 10_000
        for picture in pictures {
            picture.layer.anchorPoint = .zero
            picture.layer.position = picture.frame.origin
            picture.layer.transform = CATransform3DIdentity
            container.addSublayer(picture.layer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(container)
        CATransaction.commit()
        frameInput.filmZoomPending = { [weak self] in
            guard let self, let root = self.layer, let container = root.sublayers?.first(where: { $0.name == tag }) else { return }
            guard let zoomedHost = self.context.hosts[zoomed] else {
                container.removeFromSuperlayer()
                return
            }
            let finish: @MainActor () -> Void = { [weak self] in
                self?.layer?.sublayers?.first { $0.name == tag }?.removeFromSuperlayer()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.isHidden = false
            CATransaction.commit()
            switch (film.kind, zooming) {
            case (.z2, true):
                // A hole the zoomed pane shows through, from its old frame to its frame now.
                let mask = Self.filmHoleMask(bounds: bounds)
                container.mask = mask
                film.animate(mask, "path", from: Self.filmHole(bounds, oldZoomedFrame), to: Self.filmHole(bounds, zoomedHost.frame), completion: finish)
            case (.z2, false):
                // The old full picture only inside a frame that shrinks to the pane's place, never over that place.
                let mask = Self.filmHoleMask(bounds: bounds)
                container.mask = mask
                let place = zoomedHost.frame
                film.animate(mask, "path", from: Self.filmRing(outer: oldZoomedFrame, inner: place),
                             to: Self.filmRing(outer: place, inner: place), completion: finish)
            case (.z3, true):
                let nothing: @MainActor () -> Void = {}
                let layers = container.sublayers ?? []
                for (index, layer) in layers.enumerated() where index < frames.count {
                    let last = index == min(layers.count, frames.count) - 1
                    let exit = Self.filmSlide(frames[index], from: oldZoomedFrame, bounds: bounds)
                    film.animate(layer, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                 to: NSValue(caTransform3D: exit), completion: nothing)
                    film.animate(layer, "opacity", from: NSNumber(value: Float(1)), to: NSNumber(value: Float(0)),
                                 completion: last ? finish : nothing)
                }
            case (.z3, false):
                // The other panes, live at their final frames, slide in from the edges and fade in.
                let place = zoomedHost.frame
                var hosts: [CALayer] = []
                for (pane, host) in self.context.hosts where pane != zoomed && host.superview === self && after.panes[pane] != nil {
                    if let layer = host.layer { hosts.append(layer) }
                }
                guard !hosts.isEmpty else { return finish() }
                let nothing: @MainActor () -> Void = {}
                for (index, layer) in hosts.enumerated() {
                    let last = index == hosts.count - 1
                    let entry = Self.filmSlide(layer.frame, from: place, bounds: bounds)
                    film.animate(layer, "transform", from: NSValue(caTransform3D: entry), to: NSValue(caTransform3D: CATransform3DIdentity),
                                 completion: nothing)
                    film.animate(layer, "opacity", from: NSNumber(value: Float(0)), to: NSNumber(value: Float(1)),
                                 completion: last ? finish : nothing)
                }
            default:
                finish()
            }
        }
    }

    /// The film zoom's motion starts with the presentation that shows its final layout (`applyPresentation`).
    func runFilmZoomPending() {
        guard let run = frameInput.filmZoomPending, !frameInput.snapWaitsForContent else { return }
        frameInput.filmZoomPending = nil
        run()
    }

    private static func filmHoleMask(bounds: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.bounds = bounds
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        return mask
    }

    /// The whole screen less `hole` (even-odd).
    private static func filmHole(_ bounds: CGRect, _ hole: CGRect) -> CGPath {
        filmRing(outer: bounds, inner: hole)
    }

    /// `outer` less `inner` (even-odd); the same two rectangles in every path, so a path animation interpolates them.
    private static func filmRing(outer: CGRect, inner: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(outer)
        path.addRect(inner)
        return path
    }

    /// The move that takes `frame` out through the screen edge on the side away from `zoomed` (the larger offset axis).
    private static func filmSlide(_ frame: CGRect, from zoomed: CGRect, bounds: CGRect) -> CATransform3D {
        let dx = frame.midX - zoomed.midX, dy = frame.midY - zoomed.midY
        if abs(dx) >= abs(dy), abs(dx) > 0.5 {
            return CATransform3DMakeTranslation(dx > 0 ? bounds.maxX - frame.minX : bounds.minX - frame.maxX, 0, 0)
        }
        if abs(dy) > 0.5 {
            return CATransform3DMakeTranslation(0, dy > 0 ? bounds.maxY - frame.minY : bounds.minY - frame.maxY, 0)
        }
        return CATransform3DIdentity
    }

    /// A copy of `layer`'s tree as it shows now: the same geometry and contents, hidden layers left out.
    static func filmZoomCopy(_ layer: CALayer) -> CALayer {
        let copy = CALayer()
        copy.bounds = layer.bounds
        copy.anchorPoint = layer.anchorPoint
        copy.position = layer.position
        copy.transform = layer.transform
        copy.sublayerTransform = layer.sublayerTransform
        copy.isGeometryFlipped = layer.isGeometryFlipped
        copy.contents = layer.contents
        copy.contentsGravity = layer.contentsGravity
        copy.contentsRect = layer.contentsRect
        copy.contentsCenter = layer.contentsCenter
        copy.contentsScale = layer.contentsScale
        copy.backgroundColor = layer.backgroundColor
        copy.cornerRadius = layer.cornerRadius
        copy.maskedCorners = layer.maskedCorners
        copy.cornerCurve = layer.cornerCurve
        copy.masksToBounds = layer.masksToBounds
        copy.borderWidth = layer.borderWidth
        copy.borderColor = layer.borderColor
        copy.opacity = layer.opacity
        for sub in layer.sublayers ?? [] where !sub.isHidden && sub.opacity > 0 {
            copy.addSublayer(filmZoomCopy(sub))
        }
        return copy
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
extension LayoutModel {
    /// A film zoom (Z1, Z2 or Z3) plays: the zoom shows in the key's turn (`DaemonService.filmZoomNow`).
    @MainActor public static var filmZoomPlays: Bool { DesignSettings.shared.filmZoom.active != nil }
}
#endif
