#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// ZOOM VARIANTS film selector (``FilmZoomVariant``; DEBUG and bench builds only, branch zoom-variants/film-selector-nomerge,
/// never merged). Z1-Z4 snap a zoom to its final frames (`reconcile`): one resize, of the zoomed terminal only, its final
/// grid sent in the key's turn, the old picture held one tick (`ScreenContentView+SnapFrame`). The panes the zoom covers
/// are kept as they are (retired until the unzoom: no teardown, no resize), as the current zoom keeps them. Z2-Z4 then
/// play a motion, started by the presentation that shows the final layout, on copies of the panes' last pictures (their
/// layer trees' contents: a terminal's last frame, the tab strip; a Chromium page's own window is not in them) or on the
/// live layers:
/// - Z2 in: the other panes' pictures over the zoomed pane, with a hole that grows from its old frame to the full screen.
/// - Z2 out: the zoomed pane's old full picture over the final layout, its frame shrinking to the pane's place.
/// - Z3 in: the other panes' pictures over the zoomed pane slide out to the screen edges and fade.
/// - Z3 out: the other panes slide in from the screen edges and fade in over the zoomed pane's old full picture.
/// - Z4 in (m66): the zoomed pane's frame grows from its place to the full screen, its content (final grid) on the frame's
///   top-left, while the other panes' pictures fade out in place; one progress value drives the frame and the opacity
///   (``FilmProgressDriver``).
/// - Z4 out: the exact reverse: the zoomed pane's old full picture shrinks to its place while the other panes fade in.
/// The screen is flipped (`isFlipped`), as the pane hosts are: a frame's top-left is its (minX, minY), in layers too.
extension ScreenContentView {
    func prepareFilmZoom(_ film: FilmZoomVariant, zooming: Bool, before: ScreenGeometry, after: ScreenGeometry) {
        // A film zoom that never showed (a second key in the same tick): its covered panes are retired now.
        for pane in frameInput.filmZoomRetire { context.retire(pane, from: screenID, until: .zoom) }
        frameInput.filmZoomRetire = []
        frameInput.filmZoomPending = nil
        // A Z4 zoom in still fading its covered panes: a newer zoom takes them as they are now (an unzoom brings them
        // back from here: `returning` below), and that fade's end does nothing (`filmZoomGeneration`).
        frameInput.filmZoomGeneration &+= 1
        frameInput.filmMotionUntil = 0 // an older film's end no longer counts (set again below when this one plays)
        stopFilmFade(retiring: zooming)
        layer?.sublayers?.filter { $0.name?.hasPrefix("film-zoom-pictures-") == true }.forEach { $0.removeFromSuperlayer() }
        guard let root = layer else { return }
        let zoomed = zooming ? after.panes.keys.first : before.panes.keys.first { after.panes[$0] != nil }
        guard let zoomed, let zoomedLayer = context.hosts[zoomed]?.layer else { return }
        let animates = film.kind != .z1 && Motion.panes.animatesMovement
        // The film plays from the presentation on: the window's divider catchers wait for its end or its deadline,
        // whichever comes first (`isFilmMoving`); a press meanwhile moves them first (`LayoutRootView.endFilmMotionWait`).
        let generation = frameInput.filmZoomGeneration
        let wait = film.driver.duration + Self.filmEndGrace
        frameInput.filmMotionUntil = animates ? CACurrentMediaTime() + wait : 0
        if animates { context.filmDeadline(screenID, wait) { [weak self] in self?.filmMotionEnded(generation) } }
        // Zoom in: the panes the zoom covers stay as they are and go hidden with the presentation (retired, not torn down).
        // Zoom out: the panes the unzoom shows again wait at opacity 0 until that presentation.
        var covered: [PaneID] = [], returning: [PaneID] = []
        for (pane, host) in context.hosts where pane != zoomed && host.superview === self {
            if zooming, before.panes[pane] != nil, after.panes[pane] == nil { covered.append(pane) }
            if !zooming, after.panes[pane] != nil, before.panes[pane] == nil { returning.append(pane) }
        }
        frameInput.filmZoomRetire = covered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pane in returning { context.hosts[pane]?.layer?.opacity = 0 }
        CATransaction.commit()
        let oldZoomed = zoomedLayer.frame
        let bounds = root.bounds
        // The pictures to copy now, before the hosts take their new frames: the other panes going in, the zoomed one out.
        var pictures: [(layer: CALayer, frame: CGRect)] = []
        // Z4 in (ZOOM VARIANTS 2): no copies; the covered panes fade out live at the presentation (`filmFadeLive`).
        let fadesLive = animates && zooming && film.kind == .z4
        if animates, zooming, !fadesLive {
            for pane in covered {
                guard let source = context.hosts[pane]?.layer, source.frame.width >= 1, source.frame.height >= 1 else { continue }
                pictures.append((Self.filmZoomCopy(source), source.frame))
            }
        } else if animates, !zooming, oldZoomed.width >= 1 {
            pictures.append((Self.filmZoomCopy(zoomedLayer), oldZoomed))
        }
        // The copies go on the root now, hidden, and show with the presentation of the final layout. The pending closure
        // finds them by name (no layer captured in it: it is main-actor code stored on the frame input).
        let tag = "film-zoom-pictures-\(UInt64.random(in: 0 ... UInt64.max))"
        let frames = pictures.map(\.frame)
        if !pictures.isEmpty {
            let container = CALayer()
            container.frame = bounds
            container.bounds = bounds // the root's coordinates inside it, as the hosts' frames are
            container.name = tag
            container.isHidden = true
            container.zPosition = film.kind == .z3 && !zooming ? -1 : film.kind == .z4 && zooming ? 9_000 : 10_000
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
        }
        frameInput.filmZoomPending = { [weak self] in
            guard let self else { return }
            if fadesLive, let zoomedLayer = self.context.hosts[zoomed]?.layer {
                return MotionTrace.interval("zk.pending") {
                    self.filmFadeLive(film, zoomedLayer, from: oldZoomed, to: zoomedLayer.frame)
                }
            }
            for pane in self.frameInput.filmZoomRetire { self.context.retire(pane, from: self.screenID, until: .zoom) }
            self.frameInput.filmZoomRetire = []
            let container = self.layer?.sublayers?.first { $0.name == tag }
            guard animates, let container, let zoomedLayer = self.context.hosts[zoomed]?.layer else {
                self.filmMotionEnded(generation)
                container?.removeFromSuperlayer()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for pane in returning { self.context.hosts[pane]?.layer?.opacity = 1 }
                CATransaction.commit()
                return
            }
            let finish: @MainActor () -> Void = { [weak self] in
                self?.layer?.sublayers?.first { $0.name == tag }?.removeFromSuperlayer()
                self?.filmMotionEnded(generation)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.isHidden = false
            if film.kind != .z3, film.kind != .z4 {
                for pane in returning { self.context.hosts[pane]?.layer?.opacity = 1 }
            }
            CATransaction.commit()
            let place = zoomedLayer.frame
            let returningLayers = returning.compactMap { self.context.hosts[$0]?.layer }
            switch (film.kind, zooming) {
            case (.z4, true):
                self.filmGrow(film, zoomedLayer, from: oldZoomed, to: place, container: container, finish: finish)
            case (.z4, false):
                self.filmShrink(film, container: container, zoomed: zoomed, from: oldZoomed, to: place, fadingIn: returningLayers,
                                finish: finish)
            case (.z2, true):
                // A hole the zoomed pane shows through, from its old frame to its frame now.
                let mask = Self.filmHoleMask(bounds: bounds)
                container.mask = mask
                film.animate(mask, "path", from: Self.filmRing(outer: bounds, inner: oldZoomed),
                             to: Self.filmRing(outer: bounds, inner: place), completion: finish)
            case (.z2, false):
                // The old full picture only inside a frame that shrinks to the pane's place, never over that place.
                let mask = Self.filmHoleMask(bounds: bounds)
                container.mask = mask
                film.animate(mask, "path", from: Self.filmRing(outer: oldZoomed, inner: place),
                             to: Self.filmRing(outer: place, inner: place), completion: finish)
            case (.z3, true):
                let nothing: @MainActor () -> Void = {}
                let layers = container.sublayers ?? []
                for (index, layer) in layers.enumerated() where index < frames.count {
                    let last = index == min(layers.count, frames.count) - 1
                    let exit = Self.filmSlide(frames[index], from: oldZoomed, bounds: bounds)
                    film.animate(layer, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                 to: NSValue(caTransform3D: exit), completion: nothing)
                    film.animate(layer, "opacity", from: NSNumber(value: Float(1)), to: NSNumber(value: Float(0)),
                                 completion: last ? finish : nothing)
                }
            case (.z3, false):
                // The other panes, live at their final frames, slide in from the edges and fade in.
                guard !returningLayers.isEmpty else { return finish() }
                let nothing: @MainActor () -> Void = {}
                for (index, layer) in returningLayers.enumerated() {
                    let last = index == returningLayers.count - 1
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

    /// Z4 in: the zoomed pane (live, at its final frame and grid) shows through a frame that grows from `from` to `to`,
    /// its content on that frame's top-left (a translation of its layer and a mask of the frame's size), above the
    /// covered panes' pictures (`container`), which fade out in place; one progress value p drives all three.
    private func filmGrow(_ film: FilmZoomVariant, _ zoomed: CALayer, from: CGRect, to: CGRect, container: CALayer,
                          finish: @escaping @MainActor () -> Void) {
        let driver = film.driver // one progress table for every layer this zoom drives
        let mask = CAShapeLayer()
        mask.frame = zoomed.bounds
        mask.fillColor = NSColor.black.cgColor
        mask.path = CGPath(rect: zoomed.bounds, transform: nil)
        let maskName = "film-zoom-grow-\(UInt64.random(in: 0 ... UInt64.max))"
        mask.name = maskName
        let zBefore = zoomed.zPosition
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomed.zPosition = 9_500
        zoomed.mask = mask
        CATransaction.commit()
        let size = zoomed.bounds.size
        let nothing: @MainActor () -> Void = {}
        driver.drive(zoomed, "transform", { p in
            let r = Self.filmLerp(from, to, p)
            return NSValue(caTransform3D: CATransform3DMakeTranslation(r.minX - to.minX, r.minY - to.minY, 0))
        }, completion: nothing)
        driver.drive(mask, "path", { p in
            let r = Self.filmLerp(from, to, p)
            return CGPath(rect: CGRect(x: 0, y: 0, width: max(0, min(size.width, r.width)), height: max(0, min(size.height, r.height))),
                          transform: nil)
        }, completion: nothing)
        driver.drive(container, "opacity", { p in NSNumber(value: Float(min(1, max(0, 1 - p)))) }, completion: { [weak self] in
            // The zoomed pane's layer as it was (found again by the screen: no layer captured here).
            if let self, let layer = self.layer?.sublayers?.first(where: { $0.mask?.name == maskName }) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.mask = nil
                layer.zPosition = zBefore
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            finish()
        })
    }

    /// Z4 in, live (ZOOM VARIANTS 2): the zoomed pane grows as in ``filmGrow`` while the panes it covers fade out on the
    /// same p, their own layers and chrome (a terminal, a page and its toolbar fade together; no copy, so no blank page),
    /// still shown and visible. Their retire (hide; a page's orderOut) waits for the fade's end, off the key's turn.
    private func filmFadeLive(_ film: FilmZoomVariant, _ zoomed: CALayer, from: CGRect, to: CGRect) {
        let driver = film.driver // one progress table for every layer this zoom drives
        let covered = frameInput.filmZoomRetire
        frameInput.filmZoomRetire = []
        frameInput.filmZoomFading = covered
        let generation = frameInput.filmZoomGeneration
        let mask = CAShapeLayer()
        mask.frame = zoomed.bounds
        mask.fillColor = NSColor.black.cgColor
        mask.path = CGPath(rect: zoomed.bounds, transform: nil)
        let maskName = "film-zoom-grow-\(UInt64.random(in: 0 ... UInt64.max))"
        mask.name = maskName
        let zBefore = zoomed.zPosition
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomed.zPosition = 9_500
        zoomed.mask = mask
        CATransaction.commit()
        let size = zoomed.bounds.size
        let nothing: @MainActor () -> Void = {}
        driver.drive(zoomed, "transform", { p in
            let r = Self.filmLerp(from, to, p)
            return NSValue(caTransform3D: CATransform3DMakeTranslation(r.minX - to.minX, r.minY - to.minY, 0))
        }, completion: nothing)
        let fading = covered.compactMap { context.hosts[$0] }.flatMap { [$0.layer, $0.chrome.layer] }.compactMap { $0 }
        for layer in fading {
            driver.drive(layer, "opacity", { p in NSNumber(value: Float(min(1, max(0, 1 - p)))) }, completion: nothing)
        }
        // The end: one completion on the zoomed pane's own frame (every property ends on the same p).
        driver.drive(mask, "path", { p in
            let r = Self.filmLerp(from, to, p)
            return CGPath(rect: CGRect(x: 0, y: 0, width: max(0, min(size.width, r.width)), height: max(0, min(size.height, r.height))),
                          transform: nil)
        }, completion: { [weak self] in
            guard let self else { return }
            if let layer = self.layer?.sublayers?.first(where: { $0.mask?.name == maskName }) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.mask = nil
                layer.zPosition = zBefore
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            guard self.frameInput.filmZoomGeneration == generation else { return }
            self.stopFilmFade(retiring: true)
            self.filmMotionEnded(generation)
            self.context.requestFrames() // the next tick reports the retired panes hidden (`updateVisibility`)
        })
    }

    /// Ends a live Z4 fade: each covered pane back at full opacity (no animation), then, `retiring`, retired until the
    /// unzoom as ``filmZoomRetire`` is; not retiring (an unzoom took them back), left shown.
    func stopFilmFade(retiring: Bool) {
        guard !frameInput.filmZoomFading.isEmpty else { return }
        let panes = frameInput.filmZoomFading
        frameInput.filmZoomFading = []
        let fadingHosts = panes.compactMap { context.hosts[$0] } // before the retire takes them out of `hosts`
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Z4 pop fix (ZOOM VARIANTS 3, never merged): the covered panes go hidden in the same transaction that puts them
        // back at full opacity, before it. A separate later hide let one or more frames show them at opacity 1 over the
        // zoomed pane (the old layout "pop" ~5 frames after the zoom in lands).
        if retiring {
            for pane in panes where paneFrames[pane] == nil { context.retire(pane, from: screenID, until: .zoom) }
        }
        for host in fadingHosts {
            for layer in [host.layer, host.chrome.layer].compactMap({ $0 }) {
                layer.removeAnimation(forKey: "opacity")
                layer.opacity = host.isCoveredByPaint ? 0 : 1 // a pane covered by paint stays at 0 until the unzoom
            }
        }
        CATransaction.commit()
        #if DEBUG || CMUX_BENCH_HOOKS
        // ZOOM VARIANTS 3 pop probe (never merged): which covered panes this end retires now and which it leaves shown
        // at full opacity (still in `paneFrames`), as one span name.
        if MotionTrace.isEnabled {
            let kept = panes.filter { paneFrames[$0] != nil }.count
            let hidden = fadingHosts.filter(\.isHidden).count
            MotionTrace.interval("zk.fade.stop.ret\(retiring ? 1 : 0).n\(panes.count).inframes\(kept).hidden\(hidden)") {}
        }
        #endif
    }

    /// Z4 out: the zoomed pane's old full picture (`container`, over the final layout) shows through a frame that shrinks
    /// from `from` to its place `to`, the picture on that frame's top-left, while the panes the unzoom shows again fade
    /// in at their places; one progress value p drives all of it.
    ///
    /// One picture of the pane at a time (ZOOM VARIANTS 6, lead watched the C3 film: the old picture faded out over the
    /// live pane, so the old wrap and the new wrap showed through each other for 4-6 frames): the old picture stays
    /// opaque, then goes in one refresh with no value between, and the live pane under it shows. No pixel ever mixes the
    /// two pictures.
    ///
    /// On the curve in every refresh (ZOOM VARIANTS 7, lead watched the G4P K6 film: the swap at the new frame's landing,
    /// 3-4 refreshes in, showed the live pane at its final size at once; the nvim edge jumped from near full width to half
    /// width in one refresh where K6 is at about 25%). The old picture fills the shrinking frame until that frame is
    /// within 0.5 pt of the pane's place (``FilmProgressDriver/settles(within:)``); only then does it go, so the swap
    /// moves no edge more than 0.5 pt. The terminal's frame at the new grid lands long before (the shared resize hold
    /// waits at most 2 refreshes); the swap is a render-server switch on the motion's own clock, set in this turn.
    private func filmShrink(_ film: FilmZoomVariant, container: CALayer, zoomed pane: PaneID, from: CGRect, to: CGRect,
                            fadingIn: [CALayer], finish: @escaping @MainActor () -> Void) {
        let driver = film.driver // one progress table for every layer this zoom drives
        guard let picture = container.sublayers?.first, let host = context.hosts[pane], let live = host.layer else { return finish() }
        let mask = CAShapeLayer()
        mask.frame = container.bounds
        mask.fillColor = NSColor.black.cgColor
        mask.path = CGPath(rect: from, transform: nil)
        let generation = frameInput.filmZoomGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.mask = mask
        CATransaction.commit()
        let nothing: @MainActor () -> Void = {}
        driver.drive(picture, "transform", { p in
            let r = Self.filmLerp(from, to, p)
            return NSValue(caTransform3D: CATransform3DMakeTranslation(r.minX - from.minX, r.minY - from.minY, 0))
        }, completion: nothing)
        // The live pane at its place rides the frame's top-left on the same p (Z4 in's reverse), under the old picture
        // until the swap.
        driver.drive(live, "transform", { p in
            let r = Self.filmLerp(from, to, p)
            return NSValue(caTransform3D: CATransform3DMakeTranslation(r.minX - to.minX, r.minY - to.minY, 0))
        }, completion: nothing)
        for layer in fadingIn {
            driver.drive(layer, "opacity", { p in NSNumber(value: Float(min(1, max(0, p)))) }, completion: nothing)
        }
        // The swap: the old picture shows until the frame is within 0.5 pt of its place, then goes in one refresh.
        let travel = max(abs(to.minX - from.minX), abs(to.minY - from.minY), abs(to.maxX - from.maxX), abs(to.maxY - from.maxY))
        let swap = travel > 0.5 ? driver.settles(within: 0.5 / travel) : 0
        driver.hold(picture, "opacity", for: swap, then: NSNumber(value: Float(0)))
        // The zoomed terminal's frame at its new grid lands (a `zk.out.landed` mark for the per-refresh trace only; the
        // presenter's pass, where no transaction may begin: nothing changes here).
        let landing = Self.filmLanding(in: host)
        landing?.filmFrameLanded = { MotionTrace.interval("zk.out.landed") {} }
        // The end: one completion on the frame (every property ends on the same p).
        driver.drive(mask, "path", { p in CGPath(rect: Self.filmLerp(from, to, p).standardized, transform: nil) }, completion: { [weak self, weak landing] in
            landing?.filmFrameLanded = nil
            if let self, self.frameInput.filmZoomGeneration == generation, let live = self.context.hosts[pane]?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                live.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            finish()
        })
    }

    /// The frame at progress `p` (past 1 on a spring's overshoot) from `a` to `b`.
    nonisolated private static func filmLerp(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        let t = CGFloat(p)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// How long after its curve's duration a film zoom's motion ends when no end came (its deadline, ZOOM VARIANTS 8):
    /// the presentation that starts the film comes a refresh or two after the key, and a completion can come late.
    static let filmEndGrace = 0.1

    /// A film zoom's motion plays on this screen (``ScreenFrameInput/filmMotionUntil``).
    var isFilmMoving: Bool { frameInput.filmMotionUntil > CACurrentMediaTime() }

    /// The film zoom of `generation` ended (its last layer animation's completion, or no animation): the window's
    /// divider catchers follow the layout now, once. A newer zoom's film keeps playing.
    func filmMotionEnded(_ generation: Int) {
        guard frameInput.filmZoomGeneration == generation, frameInput.filmMotionUntil != 0 else { return }
        frameInput.filmMotionUntil = 0
        context.filmMotionEnded()
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

    /// `debug.motion` `trace_*` rows of a Z4 film zoom as the render server shows it in this refresh (presentation
    /// values, not the model; ZOOM VARIANTS 7 per-refresh trace), window points, top-left origin:
    /// `["out", x, y, w, h, picture opacity]` the shrinking frame of a zoom out and whether its old picture shows;
    /// `["live", x, y, w, h]` a pane host riding a film zoom's frame (its frame moved by its presented transform);
    /// `["in", x, y, w, h]` the growing frame of a zoom in (its mask in the zoomed host, moved the same way).
    func filmMotionRows() -> [Any] {
        guard let window, let root = layer else { return [] }
        let height = window.frame.height
        func row(_ kind: String, _ rect: CGRect, _ extra: [Double] = []) -> [Any] {
            let shown = convert(rect, to: nil)
            let numbers = [shown.minX, height - shown.maxY, shown.width, shown.height].map { (Double($0) * 100).rounded() / 100 } + extra
            return [kind as Any] + numbers.map { $0 as Any }
        }
        var rows: [Any] = []
        for sub in root.sublayers ?? [] where sub.name?.hasPrefix("film-zoom-pictures-") == true && !sub.isHidden {
            guard let mask = sub.mask as? CAShapeLayer, let path = (mask.presentation() ?? mask).path else { continue }
            let opacity = sub.sublayers?.first.map { Double(($0.presentation() ?? $0).opacity) } ?? 0
            rows.append(row("out", path.boundingBox, [(opacity * 1000).rounded() / 1000]))
        }
        for host in context.hosts.values where host.superview === self {
            guard let layer = host.layer, layer.animation(forKey: "transform") != nil || layer.mask?.name?.hasPrefix("film-zoom-grow-") == true else { continue }
            let move = (layer.presentation() ?? layer).transform
            let frame = layer.frame.offsetBy(dx: move.m41, dy: move.m42)
            if let mask = layer.mask as? CAShapeLayer, mask.name?.hasPrefix("film-zoom-grow-") == true,
               let path = (mask.presentation() ?? mask).path {
                let box = path.boundingBox
                rows.append(row("in", box.offsetBy(dx: frame.minX, dy: frame.minY)))
            } else {
                rows.append(row("live", frame))
            }
        }
        return rows
    }

    /// The first view in `view`'s tree whose frames land in a commit (the zoomed pane's terminal surface), depth first.
    static func filmLanding(in view: NSView) -> (any FilmFrameLanding)? {
        if let landing = view as? any FilmFrameLanding { return landing }
        for sub in view.subviews {
            if let landing = filmLanding(in: sub) { return landing }
        }
        return nil
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
        // Chrome text (`ChromeTextLayer`) is a fill layer masked by its glyphs: without the mask the copy shows a solid box.
        if let mask = layer.mask { copy.mask = filmZoomCopy(mask) }
        for sub in layer.sublayers ?? [] where !sub.isHidden && sub.opacity > 0 {
            copy.addSublayer(filmZoomCopy(sub))
        }
        return copy
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
extension LayoutModel {
    /// A film zoom (Z1-Z4) plays: the zoom shows in the key's turn (`DaemonService.filmZoomNow`).
    @MainActor public static var filmZoomPlays: Bool { DesignSettings.shared.filmZoom.active != nil }
    /// A `zk.*` key-turn span (``MotionTrace/interval(_:_:)``) for targets that do not import the design module.
    @MainActor public static func filmTrace<T>(_ name: String, _ body: () -> T) -> T { MotionTrace.interval(name, body) }
}
#endif
