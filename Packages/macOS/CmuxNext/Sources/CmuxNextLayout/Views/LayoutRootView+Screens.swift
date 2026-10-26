import AppKit
import CmuxNextDesign
import QuartzCore

/// Screen views: the animated screen switch.
extension LayoutRootView {
    /// Sets every screen's frame target for the switch from `old` to `new`; the caller's change turn
    /// hands it to the render server or places it (`applyScreenFrames`). Returns true if it springs.
    func switchScreens(from old: ScreenID?, to new: ScreenID?, order: [ScreenID], animated: Bool) -> Bool {
        let oldIndex = old.flatMap { order.firstIndex(of: $0) } ?? -1
        let newIndex = new.flatMap { order.firstIndex(of: $0) } ?? 0
        let direction: CGFloat = newIndex >= oldIndex ? 1 : -1
        let shift = bounds.width * 0.18
        for (id, view) in screenViews {
            guard var frame = screenFrames[id] else { continue }
            if id == new {
                if view.isHidden || frame.alpha.value < 0.01 {
                    frame = AnimatedFrame(bounds.offsetBy(dx: direction * shift, dy: 0), alpha: 0)
                }
                view.isHidden = false
                frame.setTarget(bounds, alpha: 1)
            } else if id == old {
                frame.setTarget(bounds.offsetBy(dx: -direction * shift, dy: 0), alpha: 0)
            } else {
                frame.setTarget(bounds, alpha: 0)
                frame.snap()
            }
            if !animated { frame.snap() }
            screenFrames[id] = frame
        }
        return animated
    }

    /// A screen frame is off its rest: the CPU steps the switch on display frames.
    var screensStepping: Bool {
        screenFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }

    /// Places every screen view at its frame; a screen that moved, faded
    /// or hid marks the overlay stale (its rings follow). A screen the render
    /// server still slides (``ScreenSwitchFlight``) hides when it lands, and a
    /// placement that moves or fades it here takes that property from its springs.
    func applyScreenFrames() {
        for (id, frame) in screenFrames {
            guard let view = screenViews[id] else { continue }
            let shown = (view.frame, view.alphaValue, view.isHidden)
            let springing = screenSwitch.screens.contains(id)
            if view.frame.origin != frame.rect.origin {
                if springing, let layer = view.layer { RenderSpring.stop(layer, "position") }
                view.setFrameOrigin(frame.rect.origin)
            }
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            if view.alphaValue != frame.alpha.value {
                if springing, let layer = view.layer { RenderSpring.stop(layer, "opacity") }
                view.alphaValue = frame.alpha.value
            }
            if id != model.activeScreenID && frame.alpha.value <= 0.001 && frame.alpha.target == 0 && !view.isHidden && !springing {
                view.isHidden = true
                // No frame steps a hidden screen: its pane springs land now, not when it shows again.
                view.settleMotion()
            }
            guard shown != (view.frame, view.alphaValue, view.isHidden) else { continue }
            setNeedsOverlaySync()
            // The thumb's occluder follows the screen's origin and hidden state.
            view.scrollbar?.syncOccluder()
        }
    }
}

// MARK: - The switch on the render server

/// A screen switch on the render server (chrome-parity R2, p03-rendering-030; on with
/// `motion.renderServer`). In the switch's turn every screen it moves goes to its rest frame and
/// opacity once, and Core Animation shows the new screen sliding and fading in and the old one out
/// from where each showed, on the `screen` spring token, as additive springs of each screen's
/// backing layer. The window's MotionClock never runs for it and the main thread does no work per
/// motion frame; the switch lands once, in one `RenderSpring` completion, where the old screen
/// hides. Chromium's compositor runs its transform and opacity animations the same way
/// (`cc/animation/animation_host.h`, `cc/animation/keyframe_model.h`).
struct ScreenSwitchRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .screens }

    func begin(on root: LayoutRootView, policy: MotionPolicy) -> MotionBackend {
        root.springScreensOnRenderServer() ? .renderServer : .cpuStep
    }
}

/// The render-server switch in flight: the screens its springs still move, and the serial of the
/// switch they belong to (a landing of an earlier switch finds a newer serial and does nothing).
struct ScreenSwitchFlight {
    var screens: Set<ScreenID> = []
    var serial: UInt64 = 0

    var isInFlight: Bool { !screens.isEmpty }
}

extension LayoutRootView {
    /// The change's turn moved screen frames (a switch, or a retarget of one in flight): every
    /// screen off its rest goes there now, its CPU frame rests, and the render server springs its
    /// position and opacity from where it showed, at the velocity it had. A screen the switch in
    /// flight still moved and this turn put at rest at once (a third screen the CPU snaps) stops.
    /// Returns whether it took the motion.
    func springScreensOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        let moving = screenFrames.filter { $0.value.rect != $0.value.targetRect || $0.value.alpha.value != $0.value.alpha.target }
        guard !moving.isEmpty else { return false }
        let carried = screenSwitch.screens
        let size = bounds.size
        var moves: [RenderSpring.Move] = []
        var springing: Set<ScreenID> = []
        for (id, frame) in moving {
            screenFrames[id]?.snap()
            guard let view = screenViews[id] else { continue }
            springing.insert(id)
            view.frame = CGRect(origin: frame.targetRect.origin, size: size)
            view.alphaValue = frame.alpha.target
            // A screen moves, never resizes: only its origin's velocity carries over.
            moves += view.renderSpringMoves(from: CGRect(origin: frame.rect.origin, size: size),
                                            velocity: RectComponents(x: frame.x.velocity, y: frame.y.velocity))
            if let layer = view.layer, frame.alpha.value != frame.alpha.target {
                moves.append(RenderSpring.Move(layer, "opacity", from: frame.alpha.value, to: frame.alpha.target,
                                               velocity: frame.alpha.velocity))
            }
            setNeedsOverlaySync()
            view.scrollbar?.syncOccluder()
        }
        for id in carried.subtracting(springing) {
            if let layer = screenViews[id]?.layer { Self.stopScreenSprings(layer) }
        }
        screenSwitch.serial &+= 1
        screenSwitch.screens = springing
        let serial = screenSwitch.serial
        setLayoutInMotion(true)
        Motion.panes.renderSpring(.screen).animateGroup(moves, in: self) { [weak self] finished in
            // A newer switch took over these springs: its own landing hides what it leaves.
            guard finished else { return }
            self?.screenSwitchLanded(serial)
        }
        return true
    }

    /// The render-server switch `serial` landed: the screen it faded out hides, the overlay syncs
    /// once at the rest frames, and the layout motion ends unless other motion still runs.
    func screenSwitchLanded(_ serial: UInt64) {
        guard screenSwitch.serial == serial, screenSwitch.isInFlight else { return }
        screenSwitch.screens = []
        applyScreenFrames()
        flushOverlaySync()
        endLayoutMotionIfSettled()
    }

    /// Stops the render-server switch in flight: its screens show their rest at once, and the
    /// caller's placement (``applyScreenFrames()``) hides the one that faded out and ends the layout
    /// motion (``endLayoutMotionIfSettled()``). Its completion, when it comes, finds nothing in
    /// flight. Returns whether a switch was in flight.
    @discardableResult
    func stopScreenSwitch() -> Bool {
        guard screenSwitch.isInFlight else { return false }
        for id in screenSwitch.screens {
            if let layer = screenViews[id]?.layer { Self.stopScreenSprings(layer) }
        }
        screenSwitch.screens = []
        return true
    }

    /// Ends the layout motion when nothing moves any more: no screen switch, pane spring, render
    /// spring or gesture, and no CPU frames.
    func endLayoutMotionIfSettled() {
        guard !screenSwitch.isInFlight, !driver.isRunning,
              !screenViews.values.contains(where: { $0.hasMotion || $0.userMotionActive }) else { return }
        setLayoutInMotion(false)
    }

    /// Removes the position and opacity springs a switch added on a screen's layer.
    static func stopScreenSprings(_ layer: CALayer) {
        RenderSpring.stop(layer, "position")
        RenderSpring.stop(layer, "opacity")
    }
}
