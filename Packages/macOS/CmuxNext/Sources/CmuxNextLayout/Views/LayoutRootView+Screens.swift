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
    /// placement that moves or fades it here takes that property from its
    /// springs and its rings' and dims' (the overlay sync places them again).
    func applyScreenFrames() {
        for (id, frame) in screenFrames {
            guard let view = screenViews[id] else { continue }
            let shown = (view.frame, view.alphaValue, view.isHidden)
            let springing = screenSwitch.screens.contains(id)
            if view.frame.origin != frame.rect.origin {
                if springing { stopSwitchSprings(of: id, keyPaths: ["position"]) }
                view.setFrameOrigin(frame.rect.origin)
            }
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            if view.alphaValue != frame.alpha.value {
                if springing { stopSwitchSprings(of: id, keyPaths: ["opacity"]) }
                view.alphaValue = frame.alpha.value
            }
            if id != model.activeScreenID && frame.alpha.value <= 0.001 && frame.alpha.target == 0 && !view.isHidden && !springing {
                view.isHidden = true
                // No frame steps a hidden screen: its pane springs land now, not when it shows again.
                view.settleMotion()
                // Nor does it land a resize drag: its pages lay out now.
                view.finishResizeGesture()
            }
            guard shown != (view.frame, view.alphaValue, view.isHidden) else { continue }
            setNeedsOverlaySync()
            // The thumb's occluder follows the screen's origin and hidden state.
            view.scrollbar?.syncOccluder()
        }
    }
}

// MARK: - The switch on the render server

/// A screen switch on the render server (chrome-parity R2; on with
/// `motion.renderServer`). In the switch's turn every screen it moves goes to its rest frame and
/// opacity once, the overlay syncs once at rest, and Core Animation shows the new screen sliding and
/// fading in and the old one out from where each showed, on the `screen` spring token: additive
/// springs of each screen's backing layer and, in the same group, of the rings and dims of its panes
/// (the overlay plane draws them above the screens, so they get the screen's springs). The window's
/// MotionClock never runs for it and the main thread does no work per motion frame; the switch lands
/// once, in one `RenderSpring` completion, where the old screen hides. Chromium's compositor runs its
/// transform and opacity animations the same way (`cc/animation/animation_host.h`,
/// `cc/animation/keyframe_model.h`). A screen with a page in its own child window stays on the CPU
/// step: that window follows the model frames, not a spring, until tasks 051 to 053 remove it.
/// Reduce Motion turned on mid-flight lets the springs run out (at most the `screen` settle time), as
/// Chrome's running compositor animations do; a frame the CPU steps for other motion stops them first
/// (``LayoutRootView/advanceFrame(_:)``), and the next switch snaps.
struct ScreenSwitchRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .screens }

    func begin(on root: LayoutRootView, policy: MotionPolicy) -> MotionBackend {
        root.springScreensOnRenderServer() ? .renderServer : .cpuStep
    }
}

/// The render-server switch in flight: the screens its springs still move, the ring and dim layers
/// that spring with each, the slides its turn set up for the overlay sync that ends the turn to
/// start, and the serial of the switch they belong to (a landing of an earlier switch finds a newer
/// serial and does nothing).
struct ScreenSwitchFlight {
    /// How one screen moves to its rest: where it showed minus its rest origin, its velocity, and
    /// its opacity from and to (root coordinates; points and points per second).
    struct Slide {
        var offset: CGPoint
        var velocity: CGPoint
        var fromAlpha: CGFloat
        var toAlpha: CGFloat
        var alphaVelocity: CGFloat
    }

    var screens: Set<ScreenID> = []
    /// The ring and dim layers (`PaneOverlayView`) springing with each screen.
    var chrome: [ScreenID: [CALayer]] = [:]
    /// Screens the switch's turn put at rest whose springs have not started yet.
    var pending: [ScreenID: Slide] = [:]
    var serial: UInt64 = 0

    var isInFlight: Bool { !screens.isEmpty }

    /// Nothing moves any more; the serial stays, so an earlier landing still finds it stale.
    mutating func clear() {
        screens = []
        chrome = [:]
        pending = [:]
    }
}

extension LayoutRootView {
    /// The change's turn moved screen frames (a switch, or a retarget of one in flight): every
    /// screen off its rest goes there now and its CPU frame rests; the overlay sync that ends the
    /// turn starts the springs (``startScreenSwitch()``). A screen the switch in flight still moved
    /// and this turn put at rest at once (a third screen the CPU snaps) stops. Returns whether it
    /// took the motion: not when the render server would not show it (a parked root, Reduce Motion,
    /// a sleeping or absent display), and not when a screen it moves shows a page in its own child window.
    func springScreensOnRenderServer() -> Bool { // perf-hot: 4ms motion-frame
        let moving = screenFrames.filter { $0.value.rect != $0.value.targetRect || $0.value.alpha.value != $0.value.alpha.target }
        guard !moving.isEmpty, isLive, Motion.panes.renderSpring(.screen).animates("position", in: self),
              !moving.keys.contains(where: { screenViews[$0]?.displayedHosts.contains(where: \.showsChildWindowContent) == true })
        else { return false }
        let size = bounds.size
        var slides: [ScreenID: ScreenSwitchFlight.Slide] = [:]
        for (id, frame) in moving {
            screenFrames[id]?.snap()
            guard let view = screenViews[id] else { continue }
            view.frame = CGRect(origin: frame.targetRect.origin, size: size)
            view.alphaValue = frame.alpha.target
            // A screen moves, never resizes: only its origin's velocity carries over.
            slides[id] = ScreenSwitchFlight.Slide(
                offset: CGPoint(x: frame.rect.minX - frame.targetRect.minX, y: frame.rect.minY - frame.targetRect.minY),
                velocity: CGPoint(x: frame.x.velocity, y: frame.y.velocity),
                fromAlpha: frame.alpha.value, toAlpha: frame.alpha.target, alphaVelocity: frame.alpha.velocity)
            view.scrollbar?.syncOccluder()
        }
        for id in screenSwitch.screens.subtracting(slides.keys) {
            stopSwitchSprings(of: id)
            screenSwitch.chrome[id] = nil
        }
        screenSwitch.serial &+= 1
        screenSwitch.screens = Set(slides.keys)
        screenSwitch.pending = slides
        setLayoutInMotion(true)
        // One motion.run for the switch, open until it lands (``endLayoutMotionIfSettled()``).
        context.renderMotionBegan()
        setNeedsOverlaySync()
        return true
    }

    /// The overlay sync placed the rings and dims at rest after a switch's turn: each screen the
    /// switch moves and every shown ring and dim of its panes spring from where they showed, in one
    /// group on the `screen` token from one begin time, so the chrome stays on its pane through the
    /// slide and the fade (a ring's opacity is its host's alpha times the screen's).
    func startScreenSwitch() {
        guard !screenSwitch.pending.isEmpty else { return }
        let slides = screenSwitch.pending
        screenSwitch.pending = [:]
        var moves: [RenderSpring.Move] = []
        for (id, slide) in slides {
            guard let view = screenViews[id] else { continue }
            moves += Self.slideMoves(of: view, slide, alphaScale: 1)
            var chrome = screenSwitch.chrome[id] ?? []
            for host in view.displayedHosts where host.chrome.superview === overlayPlane && !host.chrome.isHidden {
                moves += Self.slideMoves(of: host.chrome, slide, alphaScale: host.alphaValue)
                if let layer = host.chrome.layer, !chrome.contains(where: { $0 === layer }) { chrome.append(layer) }
            }
            screenSwitch.chrome[id] = chrome
        }
        let serial = screenSwitch.serial
        Motion.panes.renderSpring(.screen).animateGroup(moves, in: self) { [weak self] finished in
            // A newer switch took over these springs: its own landing hides what it leaves.
            guard finished else { return }
            self?.screenSwitchLanded(serial)
        }
    }

    /// The springs that show `view`, at its rest frame and opacity now, coming from where `slide`
    /// says its screen showed; `alphaScale` is the view's share of the screen's opacity.
    private static func slideMoves(of view: NSView, _ slide: ScreenSwitchFlight.Slide, alphaScale: CGFloat) -> [RenderSpring.Move] {
        var moves = view.renderSpringMoves(from: view.frame.offsetBy(dx: slide.offset.x, dy: slide.offset.y),
                                           velocity: RectComponents(x: slide.velocity.x, y: slide.velocity.y))
        if let layer = view.layer, slide.fromAlpha != slide.toAlpha {
            let rest = view.alphaValue
            moves.append(RenderSpring.Move(layer, RenderSpringKey<CGFloat>.opacity, from: rest + alphaScale * (slide.fromAlpha - slide.toAlpha), to: rest,
                                           velocity: alphaScale * slide.alphaVelocity))
        }
        return moves
    }

    /// The render-server switch `serial` landed: the screen it faded out hides, the overlay syncs
    /// once at the rest frames, and the layout motion ends unless other motion still runs.
    func screenSwitchLanded(_ serial: UInt64) {
        guard screenSwitch.serial == serial, screenSwitch.isInFlight else { return }
        screenSwitch.clear()
        applyScreenFrames()
        flushOverlaySync()
        endLayoutMotionIfSettled()
    }

    /// Stops the render-server switch in flight: its screens, rings and dims show their rest at once,
    /// and the caller's placement (``applyScreenFrames()``) hides the one that faded out and ends the
    /// layout motion (``endLayoutMotionIfSettled()``). Its completion, when it comes, finds nothing in
    /// flight. Returns whether a switch was in flight.
    @discardableResult
    func stopScreenSwitch() -> Bool {
        guard screenSwitch.isInFlight else { return false }
        for id in screenSwitch.screens { stopSwitchSprings(of: id) }
        screenSwitch.clear()
        return true
    }

    /// Ends the layout motion when nothing moves any more: no screen switch, pane spring, render
    /// spring or gesture, and no CPU frames; its `motion.run` rests with it.
    func endLayoutMotionIfSettled() {
        guard !screenSwitch.isInFlight, !driver.isRunning,
              !screenViews.values.contains(where: { $0.hasMotion || $0.userMotionActive }) else { return }
        setLayoutInMotion(false)
        if !rendersMotion { motionTrace.endRun() }
    }

    /// Removes the `keyPaths` springs a switch added on screen `id`'s layer and on its rings and dims.
    func stopSwitchSprings(of id: ScreenID, keyPaths: [String] = ["position", "opacity"]) {
        var layers = screenSwitch.chrome[id] ?? []
        if let layer = screenViews[id]?.layer { layers.append(layer) }
        for layer in layers {
            for keyPath in keyPaths { RenderSpring.stop(layer, keyPath) }
        }
    }
}
