#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// CLOSE VARIANTS film selector (``FilmCloseVariant``; DEBUG and bench builds only, branch
/// close-variants/film-selector-nomerge, never merged). V1, V3, V4 and V5 put the survivors at their final frames in the
/// close's turn (`reconcile` snaps them: one resize, so a terminal gets its final grid once), and the closed pane goes at
/// once. V3, V4 and V5 first copy the closed pane's last picture (its layer tree's contents: a terminal's last frame, the
/// tab strip, the ground; a Chromium page's own window is not in it) above every pane, and move it out on top.
extension ScreenContentView {
    /// The selection a close in this pass plays, nil for the current close.
    var filmCloseVariant: FilmCloseVariant? { DesignSettings.shared.filmClose.active }

    /// Copies each closed pane's picture above the screen and plays the variant's exit on it (`before`: the layout the
    /// close left, `after`: the new one, which say from which sides the survivors take its space).
    func playFilmClose(_ panes: [PaneID], variant: FilmCloseVariant, before: ScreenGeometry, after: ScreenGeometry) {
        guard variant.keepsPicture, Motion.panes.animatesMovement, let root = layer else { return }
        for pane in panes {
            guard let host = context.hosts[pane], host.superview === self, let source = host.layer, let closed = before.panes[pane] else { continue }
            let frame = host.frame
            guard frame.width >= 1, frame.height >= 1 else { continue }
            let clip = CALayer()
            clip.frame = frame
            clip.masksToBounds = true
            clip.zPosition = 10_000
            clip.name = "film-close-picture"
            let picture = Self.filmCopy(source)
            picture.anchorPoint = .zero
            picture.position = .zero
            picture.transform = CATransform3DIdentity
            clip.addSublayer(picture)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.addSublayer(clip)
            CATransaction.commit()
            // Both changes take the same time: the last one started takes the picture away when it ends.
            var changes: [(keyPath: String, from: Any, to: Any)] = []
            if variant.slides {
                let exit = Self.filmExit(of: closed, pane: pane, before: before, after: after, size: frame.size)
                changes.append(("transform", NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: exit)))
            }
            if variant.fades { changes.append(("opacity", NSNumber(value: Float(1)), NSNumber(value: Float(0)))) }
            guard let last = changes.indices.last else {
                clip.removeFromSuperlayer()
                continue
            }
            let finish: @MainActor () -> Void = { [weak clip] in clip?.removeFromSuperlayer() }
            let nothing: @MainActor () -> Void = {}
            for index in changes.indices {
                let change = changes[index]
                variant.animate(picture, change.keyPath, from: change.from, to: change.to, completion: index == last ? finish : nothing)
            }
        }
    }

    /// Where the picture goes: out through its far edge, away from the side the survivors come from (both sides: it
    /// shrinks to its middle on that axis; no side known: it stays, and a fade is all that shows).
    static func filmExit(of closed: CGRect, pane: PaneID, before: ScreenGeometry, after: ScreenGeometry, size: CGSize) -> CATransform3D {
        var left = false, right = false, above = false, below = false
        for (other, target) in after.panes where other != pane {
            guard let old = before.panes[other], target.intersects(closed.insetBy(dx: 1, dy: 1)) else { continue }
            if old.minX >= closed.maxX - 1 { right = true }
            if old.maxX <= closed.minX + 1 { left = true }
            if old.minY >= closed.maxY - 1 { below = true }
            if old.maxY <= closed.minY + 1 { above = true }
        }
        let horizontal = left || right
        if horizontal {
            if left && right { return Self.filmScale(x: 0.001, y: 1, size: size) }
            return CATransform3DMakeTranslation(right ? -size.width : size.width, 0, 0)
        }
        if above || below {
            if above && below { return Self.filmScale(x: 1, y: 0.001, size: size) }
            // View coordinates: the clip layer is not flipped against the screen's layer, which shows the view's y.
            return CATransform3DMakeTranslation(0, below ? -size.height : size.height, 0)
        }
        return CATransform3DIdentity
    }

    /// A scale about the picture's middle (its anchor is its origin).
    private static func filmScale(x: CGFloat, y: CGFloat, size: CGSize) -> CATransform3D {
        let toMiddle = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        return CATransform3DTranslate(CATransform3DScale(toMiddle, x, y, 1), -size.width / 2, -size.height / 2, 0)
    }

    /// A copy of `layer`'s tree as it shows now: the same geometry and contents (a terminal's IOSurface frame, a drawn
    /// view's backing store), hidden layers left out.
    static func filmCopy(_ layer: CALayer) -> CALayer {
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
            copy.addSublayer(filmCopy(sub))
        }
        return copy
    }
}
#endif
