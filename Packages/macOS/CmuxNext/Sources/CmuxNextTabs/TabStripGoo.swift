import AppKit
import CCmuxMotionFFI
import CmuxNextDesign
import CmuxNextDesignTokens

/// The gooey tabs (`appearance.gooeyTabs`, plans/cmux-next/gooey-tabs.md): one selection blob per strip, the selected
/// tab's body and its fillets running into the card, keyframed on the render server. Leo: "my argument is spunk ...
/// sprinyness, the goo itself, the various edge cases of delight. joy." The blob is a fill in the tabs' layer and the
/// hole in the strip's own shade of its row (the window's shade leaves the whole row to it, ``band(of:in:)``), and the
/// two run the same keyframes, so the card shows through exactly where the tab is, mid-flight too. Under `off` none of
/// this exists and the strip draws its folder tab as before.
///
/// Cost: one plan per event (two track retargets and one `cmux_goo_plan`, at most `CMUX_GOO_KEYFRAMES_MAX` outlines),
/// only the selected tab and at most one neighbour read, never a walk of the tabs and nothing per frame.
@MainActor
final class TabStripGoo {
    /// The one animation key per layer: a new event replaces it, so a burst never stacks animations.
    /// `path`, the key `Motion.set` uses too: the hover neck's ease replaces the plan's keyframes and back.
    static let key = "path"
    /// The FFI door: one plan per event, its count of calls for the constant-cost test.
    let planner = GooPlanner()
    /// The blob's fill, the folder's color, under the cells in the tabs' clip.
    let fill = CAShapeLayer()
    /// The strip's row shade less the blob (even-odd), in the strip's layer; the divider shows where it does.
    let shade = CAShapeLayer()
    let divider = CAShapeLayer()
    let dividerMask = CAShapeLayer()
    /// Media time; tests set it.
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Tests pin it; nil reads the strip's (`Motion.tabs`, Reduce Motion).
    var reducesMotion: Bool?
    private(set) var left: CmuxGooTrack?
    private(set) var right: CmuxGooTrack?
    /// The blob at rest where the last event sends it, and the plan running there.
    private(set) var blob: CmuxGooBlob?
    private(set) var plan: GooPlan?
    private var selectedID: TabID?
    private var cellCount = 0
    private weak var owner: TabCell?
    private var dragAttached: Bool?
    private var necked: TabID?
    private var clipToHost = CGAffineTransform.identity
    private var hostBounds = CGRect.zero

    /// Draws `strip`'s goo for its state now and returns whether it does (the in-card tone then draws nothing). Off,
    /// or no selected tab running into the card: tears down what it made and returns false.
    static func drive(_ strip: TabStripView) -> Bool {
        guard let cell = runningCell(strip) else {
            if let goo = strip.goo {
                goo.stop(strip)
                if !DesignSettings.shared.gooeyTabs.isOn {
                    goo.remove()
                    strip.goo = nil
                }
            }
            return false
        }
        let goo = strip.goo ?? TabStripGoo()
        strip.goo = goo
        goo.update(strip, cell: cell)
        return true
    }

    /// The selected cell whose folder the goo draws, or nil (off, not a pane's tab row, no folder tab).
    static func runningCell(_ strip: TabStripView) -> TabCell? {
        guard DesignSettings.shared.gooeyTabs.isOn, strip.isPaneTabRow, let id = strip.model.selectedID,
              let cell = strip.cells[id], cell.isSelected, cell.cornerFoot > 0, strip.placed[id] != nil else { return nil }
        return cell
    }

    /// While the goo runs, the window's shade leaves the strip's whole row to it (constant: a selection never
    /// redraws the window's shade), in `target`'s coordinates; nil otherwise.
    static func band(of strip: TabStripView, in target: CALayer) -> CGPath? {
        guard runningCell(strip) != nil, let host = strip.layer else { return nil }
        return TabStripView.map(CGPath(rect: strip.bounds, transform: nil), from: host, to: target)
    }

    // MARK: - Events

    private func update(_ strip: TabStripView, cell: TabCell) {
        install(strip)
        adopt(cell)
        recolor(strip)
        guard let id = strip.model.selectedID, let target = restBlob(strip, cell: cell) else { return }
        let tuning = GooTunables.tuning(for: DesignSettings.shared.gooeyTabs).ffi
        defer { (selectedID, cellCount) = (id, strip.cells.count) }
        if cell.isLifted { return dragNeck(strip, cell: cell, slot: target, tuning: tuning) }
        if dragAttached != nil {
            // Dropped back in its strip: absorbed. Handed to another strip: the snap below.
            dragAttached = nil
            if id == selectedID { return run(CmuxGooEventAbsorb, to: target, strip: strip, tuning: tuning, collapsed: true) }
        }
        guard let blob else { return jump(to: target) }
        let event: CmuxGooEvent?
        if id != selectedID {
            let last = selectedID
            if last != nil, last == strip.detachedID { event = CmuxGooEventSnap }
            else if strip.pendingDrop?.id == id { event = CmuxGooEventAbsorb }
            else if let last, strip.cells[last] == nil || strip.dying.contains(last) { event = CmuxGooEventClose }
            else if strip.cells.count > cellCount { event = CmuxGooEventOpen }
            else { event = CmuxGooEventSelect }
        } else if !Self.same(blob, target) {
            event = strip.movesInFlight.isEmpty ? nil : CmuxGooEventReorder
        } else {
            return
        }
        guard let event else { return jump(to: target) }
        run(event, to: target, strip: strip, tuning: tuning, collapsed: event == CmuxGooEventAbsorb)
    }

    /// The last tab closed: the blob sinks into the card's edge and its fillets flatten (no pop).
    private func stop(_ strip: TabStripView) {
        adopt(nil)
        shade.path = nil
        dividerMask.path = nil
        divider.path = nil
        guard strip.cells.isEmpty, let blob, let left, let right, strip.window != nil else {
            fill.path = nil
            self.blob = nil
            return
        }
        var melted = blob
        melted.top = blob.baseline
        melted.feet_radius = 0
        melted.corner_radius = 0
        let tuning = GooTunables.tuning(for: DesignSettings.shared.gooeyTabs).ffi
        let t = now(), mid = (blob.left + blob.right) / 2
        let plan = planner.plan(CmuxGooEventCloseLast, from: blob, to: melted,
                           left: planner.retarget(left, at: t, to: mid, spring: tuning.close),
                           right: planner.retarget(right, at: t, to: mid, spring: tuning.close),
                           tuning: tuning, reduceMotion: reduceMotion(strip))
        play(plan, on: [fill])
        fill.path = nil
        self.blob = nil
        self.plan = nil
    }

    /// Retargets the running edges from now toward `target` (velocity kept) and plays `event`'s plan: the leading
    /// edge on a stiffer spring, the trailing on a softer one, so the body stretches toward its travel.
    private func run(_ event: CmuxGooEvent, to target: CmuxGooBlob, strip: TabStripView, tuning: CmuxGooTuning,
                     collapsed: Bool) {
        let t = now()
        let from = blob ?? target
        var spring = Self.spring(event, tuning)
        let pinned = strip.model.selectedID.flatMap { strip.cells[$0]?.item.isPinned } == true
        let stretch = pinned ? 0 : tuning.stretch
        let rightward = (target.left + target.right) >= (from.left + from.right)
        var lead = spring, trail = spring
        lead.response *= max(0.2, 1 - 0.5 * stretch)
        trail.response *= 1 + stretch
        var l = left ?? Self.rest(from.left, t), r = right ?? Self.rest(from.right, t)
        if collapsed {
            // A tab coming back (dropped, or from another window): the blob grows out of the slot's middle.
            let mid = (target.left + target.right) / 2
            (l, r) = (Self.rest(mid, t), Self.rest(mid, t))
            spring = tuning.absorb
            (lead, trail) = (spring, spring)
        }
        let newLeft = planner.retarget(l, at: t, to: target.left, spring: rightward ? trail : lead)
        let newRight = planner.retarget(r, at: t, to: target.right, spring: rightward ? lead : trail)
        let plan = planner.plan(event, from: from, to: target, left: newLeft, right: newRight, tuning: tuning,
                           reduceMotion: reduceMotion(strip))
        (left, right, blob, self.plan) = (newLeft, newRight, target, plan)
        necked = nil
        play(plan, on: [fill, shade, dividerMask])
    }

    /// No motion: a resize, the first show, a scroll at rest. The edges rest at the target.
    private func jump(to target: CmuxGooBlob) {
        let t = now()
        (left, right, blob) = (Self.rest(target.left, t), Self.rest(target.right, t), target)
        plan = nil
        necked = nil
        set(planner.restPath(target))
    }

    /// A drag of the selected tab, per mouse event: the neck joins the lifted tab to its slot and narrows with
    /// distance; past `break_distance` it snaps off and retracts into the slot with a settle wobble, and back within
    /// `capture_distance` it holds again. The lifted tab draws itself (`Metrics.frameLiftSurface`).
    private func dragNeck(_ strip: TabStripView, cell: TabCell, slot: CmuxGooBlob, tuning: CmuxGooTuning) {
        guard let clip = strip.tabsClip.layer else { return }
        let layer = cell.layer
        let shown = clip.convert(layer.bounds, from: layer)
        var pill = strip.metrics.pillFrame(slotWidth: shown.width, height: shown.height)
        pill.origin = CGPoint(x: shown.minX + pill.minX, y: shown.minY + pill.minY)
        let was = dragAttached ?? true
        let neck = planner.dragNeck(slot: slot, tab: pill, wasAttached: was, tuning: tuning)
        dragAttached = neck.attached
        if neck.attached {
            blob = slot
            plan = nil
            set(neck.path)
        } else if was || !Self.same(blob ?? slot, slot) {
            blob = blob ?? slot
            run(CmuxGooEventSnap, to: slot, strip: strip, tuning: tuning, collapsed: false)
        }
    }

    /// Full goo: a hovered neighbour within the goo threshold merges with the blob (`cmux_goo_neck`), and parts
    /// again when the pointer leaves. Skipped while a plan runs, so it never fights an event.
    func hover(_ id: TabID?, in strip: TabStripView) {
        let id = id == strip.model.selectedID ? nil : id
        guard DesignSettings.shared.gooeyTabs == .full, let blob, dragAttached == nil, id != necked else { return }
        if let plan, now() < max(planner.restTime(plan.left), planner.restTime(plan.right)) { return }
        let tuning = GooTunables.tuning(for: .full).ffi
        var target = planner.restPath(blob)
        necked = nil
        if let id, let cell = strip.cells[id], let place = strip.placed[id] {
            let frame = strip.cellFrame(place, isPinned: cell.item.isPinned)
            var pill = strip.metrics.pillFrame(slotWidth: frame.width, height: frame.height)
            pill.origin = CGPoint(x: frame.minX + pill.minX, y: frame.minY + pill.minY)
            if pill.minX - blob.right <= tuning.k || blob.left - pill.maxX <= tuning.k {
                target = planner.neck(blob, with: pill, radius: Double(strip.metrics.cornerRadius), tuning: tuning)
                necked = id
            }
        }
        set(target, eased: !reduceMotion(strip))
    }

    // MARK: - Layers

    private func play(_ plan: GooPlan, on layers: [CAShapeLayer]) {
        let shadePaths = layers.count > 1 ? plan.paths.map { shadePath($0) } : []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in layers {
            let values = layer === fill ? plan.paths : shadePaths
            layer.removeAnimation(forKey: Self.key)
            layer.path = values.last
            guard values.count > 1, plan.duration > 0 else { continue }
            // motion: allow the goo's keyframes are cmux-motion's plan (cmux_goo_plan, Rust's goo springs), not a token
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = values
            animation.keyTimes = plan.keyTimes
            animation.calculationMode = .linear
            animation.duration = plan.duration
            animation.beginTime = layer.convertTime(plan.begin, from: nil)
            animation.fillMode = .backwards
            layer.add(animation, forKey: Self.key)
        }
    }

    /// Sets the blob at once, replacing any keyframes, or eases there from what shows (`Motion` `hover`, off under
    /// Reduce Motion): the hover neck.
    private func set(_ path: CGPath, eased: Bool = false) {
        let hole = shadePath(path)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (layer, value) in [(fill, path), (shade, hole), (dividerMask, hole)] {
            if eased {
                Motion.tabs.set(layer, Self.key, to: value, fade: .hover)
            } else {
                layer.removeAnimation(forKey: Self.key)
                layer.path = value
            }
        }
    }

    /// The row's shade with the blob cut out: the strip's bounds and the outline, filled even-odd.
    private func shadePath(_ blob: CGPath) -> CGPath {
        let path = CGMutablePath()
        path.addRect(hostBounds)
        path.addPath(blob, transform: clipToHost)
        return path
    }

    private func install(_ strip: TabStripView) {
        guard let host = strip.layer, let clip = strip.tabsClip.layer else { return }
        if fill.superlayer !== clip {
            for layer in [fill, shade, divider, dividerMask] {
                layer.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                 "hidden": NSNull()]
            }
            shade.fillRule = .evenOdd
            dividerMask.fillRule = .evenOdd
            dividerMask.fillColor = NSColor.black.cgColor
            divider.mask = dividerMask
            clip.insertSublayer(fill, at: 0)
            host.insertSublayer(divider, at: 0)
            host.insertSublayer(shade, at: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(origin: .zero, size: clip.bounds.size)
        shade.frame = host.bounds
        shade.masksToBounds = true
        divider.frame = host.bounds
        dividerMask.frame = divider.bounds
        CATransaction.commit()
        let o = host.convert(CGPoint.zero, from: clip), x = host.convert(CGPoint(x: 1, y: 0), from: clip)
        let y = host.convert(CGPoint(x: 0, y: 1), from: clip)
        let map = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        if map != clipToHost || host.bounds != hostBounds {
            (clipToHost, hostBounds) = (map, host.bounds)
            if let path = fill.path { set(path) }
        }
    }

    private func remove() {
        for layer in [fill, shade, divider, dividerMask] { layer.removeFromSuperlayer() }
    }

    /// The selected cell lets the goo draw its folder (its own fill and fillets go clear) and colors the fill.
    private func adopt(_ cell: TabCell?) {
        guard owner !== cell else { return }
        owner?.gooFill = nil
        owner = cell
        cell?.gooFill = fill
    }

    /// The row's shade and divider as the window's chrome draws them (`MainPaneChromeShadeView`), with actions
    /// off: a theme switch mid-flight recolors and the keyframes run on.
    private func recolor(_ strip: TabStripView) {
        let tokens = strip.themeScope.tokens
        let alpha = Metrics.mainPaneChromeShade(isDark: tokens.isDark, tokens: tokens)
        let ink = strip.themeScope.perform { Palette.chromeDivider }
        let strength = Metrics.tabRowDividerStrength
        let weight = Metrics.lineWidth(Metrics.dividerThickness)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.fillColor = Metrics.chromeFrameInk(tokens).withAlphaComponent(alpha).cgColor
        divider.fillColor = ink.withAlphaComponent(ink.alphaComponent * strength).cgColor
        divider.path = strength > 0 && !strip.meetsToolbar
            ? CGPath(rect: CGRect(x: 0, y: hostBounds.maxY - weight, width: hostBounds.width, height: weight), transform: nil)
            : nil
        CATransaction.commit()
    }

    // MARK: - Geometry

    /// The selected tab's blob at rest in the tabs' clip, the shape of `TabCell.folderPath`: its pill down to the
    /// card, its fillets scaled by the level, clamped to the visible run.
    private func restBlob(_ strip: TabStripView, cell: TabCell) -> CmuxGooBlob? {
        guard let id = strip.model.selectedID, let place = strip.placed[id], let clip = strip.tabsClip.layer else { return nil }
        let frame = strip.cellFrame(place, isPinned: cell.item.isPinned)
        let pill = strip.metrics.pillFrame(slotWidth: frame.width, height: frame.height)
        let left = max(clip.bounds.minX, frame.minX + pill.minX)
        let right = min(clip.bounds.maxX, frame.minX + pill.maxX)
        let top = frame.minY + pill.minY, baseline = frame.minY + pill.maxY + cell.cornerFoot
        guard right > left, baseline > top else { return nil }
        let level = GooTunables.tuning(for: DesignSettings.shared.gooeyTabs)
        let radius = min(strip.metrics.cornerRadius, (right - left) / 2, (baseline - top) / 2)
        return CmuxGooBlob(left: left, right: right, top: top, baseline: baseline, corner_radius: radius,
                           feet_radius: CornerFlush.current.feetRadius * level.feetScale,
                           skips_leading: cell.cornerFeetSkipsLeading)
    }

    private func reduceMotion(_ strip: TabStripView) -> Bool { reducesMotion ?? strip.reduceMotion }

    private static func rest(_ x: Double, _ t: Double) -> CmuxGooTrack {
        // A track at rest: its spring never runs (the next event retargets it with that event's own).
        CmuxGooTrack(x0: x, v0: 0, target: x, start: t, spring: CmuxGooSpring(response: 0.3, damping_fraction: 1)) // motion: allow a resting track's placeholder, not a token
    }

    private static func same(_ a: CmuxGooBlob, _ b: CmuxGooBlob) -> Bool {
        let edges = [a.left - b.left, a.right - b.right, a.top - b.top, a.baseline - b.baseline]
        let radii = [a.corner_radius - b.corner_radius, a.feet_radius - b.feet_radius]
        return (edges + radii).allSatisfy { $0 == 0 } && a.skips_leading == b.skips_leading
    }

    private static func spring(_ event: CmuxGooEvent, _ tuning: CmuxGooTuning) -> CmuxGooSpring {
        switch event {
        case CmuxGooEventOpen: tuning.open
        case CmuxGooEventClose, CmuxGooEventCloseLast: tuning.close
        case CmuxGooEventReorder: tuning.reorder
        case CmuxGooEventSnap: tuning.snap
        case CmuxGooEventAbsorb: tuning.absorb
        default: tuning.select
        }
    }
}
