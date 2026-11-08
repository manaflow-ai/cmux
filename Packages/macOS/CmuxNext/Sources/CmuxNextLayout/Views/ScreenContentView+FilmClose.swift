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
        // A text label's layer is its colour through a glyph mask: without the mask the copy is a solid light box (V6 films
        // on build a65b64cf showed the closed pane's tab title as a light bar).
        copy.mask = layer.mask.map { filmCopy($0) }
        copy.compositingFilter = layer.compositingFilter
        copy.filters = layer.filters
        for sub in layer.sublayers ?? [] where !sub.isHidden && sub.opacity > 0 {
            copy.addSublayer(filmCopy(sub))
        }
        return copy
    }
}
/// A V0/V2 close on a CURVE SET curve (``FilmCloseVariant/frameCurve``; never ships): each pane and divider frame moves from
/// where it showed when the close began to its target by the curve's progress at the time the motion has run (the springs'
/// frame clock: each step's `dt`), and lands when the curve ends (a spring once it stays within 0.5 pt of rest).
struct FilmCurveRun {
    var elapsed: Double = 0
    let shape: FilmCloseVariant.Shape
    let end: Double
    let panes: [PaneID: (from: CGRect, to: CGRect)]
    let dividers: [DividerHandleView.Kind: (from: CGRect, to: CGRect)]
}

/// A V6 close's picture (cmux-ad m67; never ships): the closed pane's last picture in place above every pane, its opacity
/// 1 - the curve's progress at the time it has run (the same frame clock and curve as the frames' ``FilmCurveRun``, so
/// one value drives both), clamped to 0...1 where a spring passes its rest. Each closed pane's picture keeps its own
/// progress: a later close does not restart or drop it.
struct FilmFade {
    let layer: CALayer
    var elapsed: Double = 0
    let shape: FilmCloseVariant.Shape
    let end: Double
}

extension ScreenContentView {
    /// V6: each closed pane's last picture goes above the panes, at its place, fully opaque (`reconcile`, in the close's
    /// turn, before the closed panes go to `closingPanes`).
    func addFilmFades(_ panes: [PaneID]) {
        guard let shape = DesignSettings.shared.filmClose.frameCurve, Motion.panes.animatesMovement, let root = layer else { return }
        for pane in panes {
            guard let host = context.hosts[pane], host.superview === self, let source = host.layer else { continue }
            let frame = host.frame
            guard frame.width >= 1, frame.height >= 1 else { continue }
            let clip = CALayer()
            clip.frame = frame
            clip.masksToBounds = true
            clip.zPosition = 10_000
            clip.name = "film-close-fade"
            clip.actions = ["opacity": NSNull(), kCAOnOrderOut: NSNull(), kCAOnOrderIn: NSNull()]
            let picture = Self.filmCopy(source)
            picture.anchorPoint = .zero
            picture.position = .zero
            picture.transform = CATransform3DIdentity
            clip.addSublayer(picture)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.addSublayer(clip)
            CATransaction.commit()
            let travel = Double(max(frame.width, frame.height) * scale)
            filmFades.append(FilmFade(layer: clip, shape: shape, end: shape.endSeconds(travel: travel)))
            FilmCloseVariant.count("fades")
        }
    }

    /// One frame of every V6 picture's fade; true while one still shows.
    func advanceFilmFades(_ dt: Double) -> Bool {
        guard !filmFades.isEmpty else { return false }
        // Plain property sets (the clip has no implicit actions): no transaction begins here, in the frame step.
        var kept: [FilmFade] = []
        for var fade in filmFades {
            fade.elapsed += dt
            if fade.elapsed >= fade.end {
                fade.layer.removeFromSuperlayer()
                continue
            }
            fade.layer.opacity = Float(min(1, max(0, 1 - fade.shape.progress(fade.elapsed))))
            kept.append(fade)
        }
        filmFades = kept
        return !kept.isEmpty
    }

    /// A close's frames start moving (`reconcile`): on the selected curve, if one is named; a run already going to the same
    /// targets keeps going (the close's later passes, its daemon echo, retarget nothing).
    func startFilmCurve() {
        guard let shape = DesignSettings.shared.filmClose.frameCurve else {
            filmCurveRun = nil
            return
        }
        if let run = filmCurveRun, run.panes.allSatisfy({ paneFrames[$0.key]?.targetRect == $0.value.to }),
           run.dividers.allSatisfy({ dividerFrames[$0.key]?.targetRect == $0.value.to }) { return }
        var travel: CGFloat = 0
        func path(_ frame: AnimatedFrame) -> (from: CGRect, to: CGRect) {
            let (a, b) = (frame.rect, frame.targetRect)
            travel = max(travel, abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
            return (a, b)
        }
        let panes = paneFrames.mapValues(path), dividers = dividerFrames.mapValues(path)
        filmCurveRun = FilmCurveRun(shape: shape, end: shape.endSeconds(travel: Double(travel) * scale), panes: panes, dividers: dividers)
        FilmCloseVariant.count("curve_runs")
    }

    /// One frame of the curve run: nil when none runs (or a later change retargeted a frame: the springs take over from
    /// where it shows), else whether it still moves.
    func advanceFilmCurve(_ dt: Double) -> Bool? {
        guard var run = filmCurveRun else { return nil }
        guard run.panes.allSatisfy({ paneFrames[$0.key]?.targetRect == $0.value.to }),
              run.dividers.allSatisfy({ dividerFrames[$0.key]?.targetRect == $0.value.to }) else {
            filmCurveRun = nil
            return nil
        }
        run.elapsed += dt
        let done = run.elapsed >= run.end
        let p = CGFloat(done ? 1 : run.shape.progress(run.elapsed))
        func place(_ frame: inout AnimatedFrame, _ path: (from: CGRect, to: CGRect)) {
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
            let minX = lerp(path.from.minX, path.to.minX), minY = lerp(path.from.minY, path.to.minY)
            let maxX = lerp(path.from.maxX, path.to.maxX), maxY = lerp(path.from.maxY, path.to.maxY)
            (frame.x.value, frame.y.value, frame.width.value, frame.height.value) = (minX, minY, max(0, maxX - minX), max(0, maxY - minY))
            (frame.x.velocity, frame.y.velocity, frame.width.velocity, frame.height.velocity) = (0, 0, 0, 0)
            frame.alpha.snap()
            if done { frame.snapGeometry() }
        }
        for key in Array(paneFrames.keys) {
            guard var frame = paneFrames[key] else { continue }
            if let path = run.panes[key] { place(&frame, path) } else { frame.snap() }
            paneFrames[key] = frame
        }
        for key in Array(dividerFrames.keys) {
            guard var frame = dividerFrames[key] else { continue }
            if let path = run.dividers[key] { place(&frame, path) } else { frame.snap() }
            dividerFrames[key] = frame
        }
        filmCurveRun = done ? nil : run
        return !done
    }
}
#endif
