import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// The terminal cursor on the render server (feature `terminalCursorLayer`, p03-rendering-091): a sublayer
/// of the surface view's layer shows the cursor cell Ghostty rendered (``TerminalCursorState/Image``), and
/// the blink is a discrete opacity keyframe the render server runs. Ghostty, with an external cursor, never
/// draws or blinks the cursor itself, so a steady or blinking cursor costs the renderer no frame and the app
/// no main-thread work.
///
/// Chromium does the same for its caret: the caret is its own layer, and blinking changes only that layer's
/// visibility (`third_party/blink/renderer/core/editing/frame_caret.cc`, `FrameCaret::CaretBlinkTimerFired`
/// asks for a paint of the caret's display item, never the page). Here the blink is in the render server, so
/// not even the app wakes; like Chromium, a hidden or occluded page blinks no caret (``LoopVisibility``).
///
/// The blink runs through ``LoopVisibility`` (off while the view is hidden, parked, out of its window or the
/// window is occluded or minimized) and the `indicators` motion gate: with Reduce Motion, the master switch
/// or `ui.animations.indicators` off, or a cursor that does not blink, the cursor is steady.
@MainActor final class TerminalCursorLayer {
    /// The cursor sits over Ghostty's content (its layer and the layers its renderer adds) whenever they were added.
    static let zPosition: CGFloat = 1
    /// The surface view's own subviews (the copy-mode box and badge, predictive echo) stay over the cursor, as they
    /// were over the cursor Ghostty drew.
    static let subviewZPosition: CGFloat = 2
    /// The blink's animation key on ``layer``.
    static let blinkKey = "terminal.cursor.blink"
    /// The pinned GhosttyNextKit publishes the cursor (`GHOSTTY_EXTERNAL_CURSOR`, Package.swift); without it
    /// Ghostty draws its own and no view makes this layer.
    #if GHOSTTY_EXTERNAL_CURSOR
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif

    /// The layer that shows the cursor cell.
    let layer = CALayer()
    /// The last cursor Ghostty published; nil before the first.
    private(set) var state: TerminalCursorState?
    private let loops: LoopVisibility
    private let clock: SpinnerClock
    private let gate: MotionGate
    private var viewHeight: CGFloat = 0

    /// - Parameters:
    ///   - gate: Decides whether the cursor blinks (``MotionPolicy/animatesBlinks``); tests pass their own.
    ///   - clock: The media-time clock the blink's phase is counted from; tests pass fixed times.
    init(gate: MotionGate = Motion.indicators, clock: SpinnerClock = SpinnerClock()) {
        self.gate = gate
        self.clock = clock
        loops = LoopVisibility("terminal.cursor", clock: clock)
        layer.name = "terminal.cursor"
        layer.zPosition = Self.zPosition
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.isHidden = true
        // Every change applies in the frame it is made: the cursor jumps to its cell, as Ghostty's did.
        let still = NSNull()
        layer.actions = ["contents": still, "position": still, "bounds": still, "hidden": still,
                         "opacity": still, "contentsScale": still]
    }

    /// The cursor's place in the visibility tree: its blink runs only while it is visible.
    var node: VisibilityNode { loops.node }

    /// Whether the blink is on the layer now (0 while hidden, steady or not blinking).
    var isBlinking: Bool { loops.runningCount > 0 }

    /// Adds the cursor over `host`, the surface view's layer.
    func install(on host: CALayer) {
        guard layer.superlayer !== host else { return }
        layer.contentsScale = host.contentsScale
        host.addSublayer(layer)
    }

    /// The view moved to `window` (`viewDidMoveToWindow`).
    func place(in window: NSWindow?) {
        loops.place(in: window)
        if let window { layer.contentsScale = window.backingScaleFactor }
    }

    /// The view is shown in its window, not hidden or parked.
    func setShown(_ shown: Bool) {
        node.set(shown ? .visible : .hidden)
    }

    /// Shows the cursor Ghostty published, in a view `viewHeight` points tall. A move or a new cell starts
    /// the blink again from shown, as Ghostty restarts its blink timer when the cursor changes.
    func show(_ state: TerminalCursorState, viewHeight: CGFloat) {
        self.state = state
        self.viewHeight = viewHeight
        layer.contents = state.image?.surface
        layer.frame = state.layerFrame(viewHeight: viewHeight)
        layer.isHidden = !state.visible || state.image == nil
        followBlink()
    }

    /// The view's height changed: the cell keeps its distance from the top.
    func layout(viewHeight: CGFloat) {
        guard viewHeight != self.viewHeight, let state else { return }
        self.viewHeight = viewHeight
        layer.frame = state.layerFrame(viewHeight: viewHeight)
    }

    private func followBlink() {
        layer.opacity = 1
        guard let state, state.visible, state.blinking, state.image != nil else {
            loops.detach(layer, key: Self.blinkKey)
            return
        }
        let interval = state.blinkInterval > 0 ? state.blinkInterval : TerminalCursorState.defaultBlinkInterval
        loops.attach(layer, key: Self.blinkKey) { [weak self] in self?.blink(interval: interval) }
    }

    /// One blink: shown for `interval`, hidden for `interval`, repeated; nil keeps the cursor steady. It
    /// begins shown at the moment it is made (``LoopVisibility`` adds it at the shared clock's phase, and the
    /// time offset takes that phase back), so a cursor that moved or showed again is seen at once.
    private func blink(interval: TimeInterval) -> CAAnimation? {
        guard gate.policy.animatesBlinks else { return nil }
        let cycle = 2 * interval
        // motion: allow the period is the terminal's cursor blink interval (Ghostty's config), not a motion token; the indicators gate's animatesBlinks (master switch, category, Reduce Motion) decides whether it runs at all
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5]
        blink.calculationMode = .discrete
        blink.duration = cycle
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        blink.timeOffset = cycle * (1 - clock.phase(cycle: cycle))
        // Two changes a cycle: the render server draws the layer at the step rate, not the display's.
        blink.preferredFrameRateRange = FrameRate.stepping(2, every: cycle).range
        return blink
    }
}
