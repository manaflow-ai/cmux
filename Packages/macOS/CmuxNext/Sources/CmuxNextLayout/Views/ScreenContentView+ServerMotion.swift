import AppKit
import CmuxNextDesign
import QuartzCore

/// A split whose new pane slides in beside a chat (`PaneArrival.slidingIn`), moved by the render server instead of the
/// main thread's frame steps.
///
/// Leo, 2026-11-06: "we need to have our animations be more one-step ... their agent pane flows smoothly when a thing
/// opens up on the right even when there's big lag on the computer". Every frame of a main-thread spring is a main-thread
/// pass: under load (STRESS, 2026-11-07) the main thread stalls 50 to 120 ms several times in a reopen's 300 ms, the
/// window shows the same picture for those frames, and the slide stands still mid-way and goes on: two or three motions
/// instead of one. In this split nothing lays out per frame anyway (the chat holds its content at its rest size and the
/// new pane enters at its final width), so the whole motion is geometry: every frame lands at rest in the change's own
/// pass, and the render server carries what shows from where it was, on additive springs of the same token, all from one
/// begin time. The chat's shrink, the divider and the new pane's slide then move together in every composited frame,
/// whatever the main thread does, and nothing is left to land after the springs end.
struct ScreenServerMotion {
    /// Where each moving pane and divider showed when the change came, in spring (strip) coordinates.
    var panes: [PaneID: CGRect]
    var dividers: [DividerHandleView.Kind: CGRect]
    /// The pane spring the change took (`ScreenPaneMotionState.frameSpring`).
    let token: MotionSpring
}

/// A host's share of a ``ScreenServerMotion``, for its overlay (`LayoutRootView.syncOverlay`).
struct PaneServerMotion {
    /// The host's frame when the motion began, in its screen's coordinates.
    let start: CGRect
    /// Media time the springs began at.
    let begin: CFTimeInterval
    let token: MotionSpring
}

extension ScreenContentView {
    /// Hands this change's slide-in to the render server when nothing in it lays out per frame: every pane it moves
    /// either holds its content in motion (a chat) or keeps its size (the panel sliding in at its final width), no dock,
    /// zoom, row or scroll area moves, and no drag or pan is under way. The frames land now; the next presentation pass
    /// places them at rest and starts the springs (``startServerMotion(strip:scale:)``).
    func handOffToRenderServer(arrivals: [PaneID: PaneArrival]) {
        guard context.springsOnRenderServer(), window != nil, !context.reduceMotion,
              arrivals.values.allSatisfy(\.slides), newDockColumns.isEmpty, zoomMotion.pane == nil,
              activeDrag == nil, !isUserScrolling, !rowsMoving, !areasMoving, !holdsContentForKeyResize else { return }
        var panes: [PaneID: CGRect] = [:]
        for (pane, frame) in paneFrames where frame.rect != frame.targetRect {
            let keepsSize = abs(frame.rect.width - frame.targetRect.width) < 0.01 && abs(frame.rect.height - frame.targetRect.height) < 0.01
            guard keepsSize || context.hosts[pane]?.holdsContentWhileMoving == true else { return }
            panes[pane] = frame.rect
        }
        guard !panes.isEmpty else { return }
        var dividers: [DividerHandleView.Kind: CGRect] = [:]
        for (kind, frame) in dividerFrames where frame.rect != frame.targetRect { dividers[kind] = frame.rect }
        for pane in panes.keys {
            guard var frame = paneFrames[pane] else { continue }
            frame.snap()
            paneFrames[pane] = frame
        }
        for kind in dividers.keys {
            guard var frame = dividerFrames[kind] else { continue }
            frame.snap()
            dividerFrames[kind] = frame
        }
        serverMotion = ScreenServerMotion(panes: panes, dividers: dividers, token: motionState.frameSpring)
    }

    /// Starts a handed-off motion's springs, in the presentation pass that placed its frames at rest: each host and
    /// divider shows its start frame (placed as that pass places a frame: camera offsets, then the pixel grid) and springs
    /// to where it rests, all from one begin time.
    func startServerMotion(strip: CGFloat, scale: CGFloat) {
        guard let motion = serverMotion else { return }
        serverMotion = nil
        let begin = CACurrentMediaTime()
        for (pane, start) in motion.panes {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let placed = start.offsetBy(dx: (geometry.scrolls(pane: pane) ? strip : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
                .pixelEdges(scale)
            guard placed != host.frame else { continue }
            ServerSpring.carry(host, from: placed, token: motion.token, begin: begin)
            host.serverMotion = PaneServerMotion(start: placed, begin: begin, token: motion.token)
        }
        for (kind, start) in motion.dividers {
            guard let view = dividerViews[kind] else { continue }
            let placed = start.offsetBy(dx: (scrolls(kind) ? strip : 0) - areaOffset(of: kind), dy: -rowOffset(of: kind)).pixelEdges(scale)
            guard placed != view.frame else { continue }
            ServerSpring.carry(view, from: placed, token: motion.token, begin: begin)
        }
        // The layout's ticks run until the springs end (`LayoutRootView.advanceFrame`): Reduce Motion or the window going
        // out of sight lands them there.
        context.requestFrames()
    }
}

extension ScreenContentView {
    /// A render-server slide still runs on a host or divider of this screen (its frames are already at rest).
    var hasServerMotion: Bool {
        serverMotion != nil || paneFrames.keys.contains { context.hosts[$0].map(ServerSpring.isCarrying) == true }
            || dividerViews.values.contains(where: ServerSpring.isCarrying)
    }

    /// Lands a render-server slide now (Reduce Motion, the window or its screen out of sight, a parked workspace): its
    /// springs go and every host, divider and ring shows its frame at rest, which is where the model already is.
    func stopServerMotion() {
        serverMotion = nil
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane] else { continue }
            host.serverMotion = nil
            ServerSpring.stop(host)
            ServerSpring.stop(host.chrome)
        }
        for view in dividerViews.values { ServerSpring.stop(view) }
    }

    /// A new layout takes over (any `reconcile`: a close or another split mid-slide, a resize, Reduce Motion): the
    /// render-server springs still running go, and each frame they carried takes the place it shows now as its spring's
    /// value, so the new change springs (or snaps) from what is on screen. Left running, their offset would add to the
    /// new motion and carry the panes past or back from where it puts them.
    func takeBackServerMotion() {
        serverMotion = nil
        let strip = stripShift
        for pane in Array(paneFrames.keys) {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.serverMotion = nil
            ServerSpring.stop(host.chrome)
            guard let shown = ServerSpring.stop(host), var frame = paneFrames[pane] else { continue }
            let rect = shown.offsetBy(dx: -((geometry.scrolls(pane: pane) ? strip : 0) - areaOffset(of: pane)), dy: rowOffset(of: pane))
            (frame.x.value, frame.y.value, frame.width.value, frame.height.value) = (rect.minX, rect.minY, rect.width, rect.height)
            paneFrames[pane] = frame
        }
        for (kind, view) in dividerViews {
            guard let shown = ServerSpring.stop(view), var frame = dividerFrames[kind] else { continue }
            let rect = shown.offsetBy(dx: -((scrolls(kind) ? strip : 0) - areaOffset(of: kind)), dy: rowOffset(of: kind))
            (frame.x.value, frame.y.value, frame.width.value, frame.height.value) = (rect.minX, rect.minY, rect.width, rect.height)
            dividerFrames[kind] = frame
        }
    }
}

/// Additive render-server springs that carry a view from a start frame to the frame it already has.
@MainActor
enum ServerSpring {
    /// The key prefix of the springs ``carry(_:from:token:begin:)`` adds.
    static let key = "serverMotion"

    /// Springs what `view` shows from `start` (its superview's coordinates) to its frame on the `token` pane spring,
    /// from media time `begin`: the model frame is already the destination (hit tests and later passes read it), and an
    /// additive spring per geometry key carries the difference down to zero. A spring still carrying an earlier
    /// difference keeps running and adds to this one, so a change mid-motion never jumps.
    static func carry(_ view: NSView, from start: CGRect, token: MotionSpring, begin: CFTimeInterval) {
        // The caller decided the motion animates (`LayoutViewContext.reduceMotion`): Reduce Motion never gets here.
        guard let layer = view.layer else { return }
        let end = view.frame
        // The layer's frame is the view's in its superlayer, mirrored vertically when that space is flipped against the view's.
        let mirrored = abs(layer.frame.minY - end.minY) > 0.5
        let dx = start.minX - end.minX, dw = start.width - end.width, dh = start.height - end.height
        let dy = mirrored ? -((start.maxY) - (end.maxY)) : start.minY - end.minY
        let anchor = layer.anchorPoint
        let position = CGPoint(x: dx + anchor.x * dw, y: dy + anchor.y * dh)
        let size = CGSize(width: dw, height: dh)
        // Ends where a step would show nothing: a tenth of a point of the largest travel left.
        let travel = max(abs(dx), abs(dy), abs(dw), abs(dh), 1)
        let local = layer.convertTime(begin, from: nil)
        if position != .zero { add(spring(token, "position", from: NSValue(point: position), to: NSValue(point: .zero), travel: travel), to: layer, at: local, "position") }
        if size != .zero { add(spring(token, "bounds.size", from: NSValue(size: size), to: NSValue(size: .zero), travel: travel), to: layer, at: local, "size") }
    }

    /// Whether ``carry(_:from:token:begin:)``'s springs still run on `view`.
    static func isCarrying(_ view: NSView) -> Bool {
        view.layer?.animationKeys()?.contains { $0.hasPrefix("\(key).") } == true
    }

    /// Takes ``carry(_:from:token:begin:)``'s springs off `view` and returns the frame it showed with them (its
    /// superview's coordinates), or nil when none was running.
    @discardableResult
    static func stop(_ view: NSView) -> CGRect? {
        guard let layer = view.layer else { return nil }
        let keys = (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(key).") }
        guard !keys.isEmpty else { return nil }
        let end = view.frame
        let shown = layer.presentation()
        for name in keys { layer.removeAnimation(forKey: name) }
        guard let shown else { return nil }
        // `carry`'s offsets read back: the presented layer against the model one, in the view's space.
        let mirrored = abs(layer.frame.minY - end.minY) > 0.5
        let anchor = layer.anchorPoint
        let dw = shown.bounds.width - layer.bounds.width, dh = shown.bounds.height - layer.bounds.height
        let dx = shown.position.x - layer.position.x - anchor.x * dw
        let layerDy = shown.position.y - layer.position.y - anchor.y * dh
        let dy = mirrored ? -layerDy - dh : layerDy
        return CGRect(x: end.minX + dx, y: end.minY + dy, width: end.width + dw, height: end.height + dh)
    }

    private static func spring(_ token: MotionSpring, _ keyPath: String, from: NSValue, to: NSValue, travel: CGFloat) -> CASpringAnimation {
        let animation = Motion.panes.springAnimation(token, keyPath, from: from, to: to)
        let rest = Double(restTravel / travel)
        animation.duration = max(animation.duration, Motion.panes.spring(token).settlingTime(within: rest))
        animation.isAdditive = true
        // A compositor sample before the begin time carries the start difference too, never the destination first.
        animation.fillMode = .backwards
        return animation
    }

    private static func add(_ animation: CASpringAnimation, to layer: CALayer, at begin: CFTimeInterval, _ name: String) {
        animation.beginTime = begin
        // Keyed by its begin time: a later motion adds its own springs beside one still running.
        layer.add(animation, forKey: "\(key).\(name).\(begin)")
    }

    /// Points of travel left when a spring ends (its envelope bound): under a tenth of a point, no frame shows the end.
    private static let restTravel: CGFloat = 0.1
}
