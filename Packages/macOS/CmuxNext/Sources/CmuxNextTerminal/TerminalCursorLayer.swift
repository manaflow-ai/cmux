import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// The terminal cursor on the render server (feature `terminalCursorLayer`): a sublayer
/// of the surface view's layer shows the cursor cell Ghostty rendered, and the blink is a discrete opacity
/// keyframe the render server runs. Ghostty, with an external cursor, never draws or blinks the cursor itself,
/// so a steady or blinking cursor costs the renderer no frame and the app no main-thread work.
///
/// The cell's pixels and place go with Ghostty's frame (``TerminalCursorPresenter``); this main-actor half
/// owns the blink. Chromium does the same for its caret: the caret is its own layer, and blinking changes only
/// that layer's visibility (`third_party/blink/renderer/core/editing/frame_caret.cc`,
/// `FrameCaret::CaretBlinkTimerFired` asks for a paint of the caret's display item, never the page). Here the
/// blink is in the render server, so not even the app wakes; like Chromium, a hidden or occluded page blinks
/// no caret (``LoopVisibility``).
///
/// The blink runs through ``LoopVisibility`` (off while the view is hidden, parked, out of its window or the
/// window is occluded or minimized) and the `indicators` motion gate: with Reduce Motion, the master switch
/// or `ui.animations.indicators` off, or a cursor that does not blink, the cursor is steady. A change of those
/// settings applies to a blinking cursor at once (``AppearanceSignals/Signal/motion``), not at its next move.
@MainActor final class TerminalCursorLayer {
    /// The cursor sits over Ghostty's content (its layer and the layers its renderer adds) whenever they were added.
    static let zPosition: CGFloat = 1
    /// The surface view's own subviews (the copy-mode box and badge, predictive echo) stay over the cursor, as they
    /// were over the cursor Ghostty drew.
    static let subviewZPosition: CGFloat = 2
    /// The blink's animation key on ``container``.
    static let blinkKey = "terminal.cursor.blink"
    /// The pinned GhosttyNextKit publishes the cursor (`GHOSTTY_EXTERNAL_CURSOR`, Package.swift); without it
    /// Ghostty draws its own and no view makes this layer.
    #if GHOSTTY_EXTERNAL_CURSOR
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif

    /// The half Ghostty's present reaches off main; the surface's bridge holds it for the cursor callback.
    let presenter = TerminalCursorPresenter()
    /// The blink of the last cell main took; nil before the first.
    private(set) var blink: TerminalCursorState.Blink?
    private let loops: LoopVisibility
    private let clock: SpinnerClock
    private let gate: MotionGate
    private let motionSignals: AppearanceSignals
    /// Held only while a blink is wanted: a change of the motion settings makes the blink again.
    private var motionWatch: AppearanceSignals.Subscription?

    /// - Parameters:
    ///   - gate: Decides whether the cursor blinks (``MotionPolicy/animatesBlinks``); tests pass their own.
    ///   - motionSignals: Where a change of the gate's settings is announced (``AppearanceSignals/Signal/motion``).
    ///   - clock: The media-time clock the blink's phase is counted from; tests pass fixed times.
    init(gate: MotionGate = Motion.indicators, motionSignals: AppearanceSignals = DesignSettings.shared.signals,
         clock: SpinnerClock = SpinnerClock()) {
        self.gate = gate
        self.motionSignals = motionSignals
        self.clock = clock
        loops = LoopVisibility("terminal.cursor", clock: clock)
        container.zPosition = Self.zPosition
    }

    /// The flipped layer the size of the view that carries the blink.
    var container: CALayer { presenter.layers.container }
    /// The cursor cell (``TerminalCursorPresenter``).
    var cell: CALayer { presenter.layers.cell }

    /// The cursor's place in the visibility tree: its blink runs only while it is visible.
    var node: VisibilityNode { loops.node }

    /// Whether the blink is on the layer now (0 while hidden, steady or not blinking).
    var isBlinking: Bool { loops.runningCount > 0 }

    /// Adds the cursor over `host`, the surface view's layer.
    func install(on host: CALayer) {
        guard container.superlayer !== host else { return }
        setScale(host.contentsScale)
        container.frame = host.bounds
        host.addSublayer(container)
    }

    /// The view is `size` points: the cell keeps its place from the top-left corner, as Ghostty's frame does.
    func layout(size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
    }

    /// The view's backing scale: Ghostty's cell pixels are shown at it.
    func setScale(_ scale: CGFloat) {
        container.contentsScale = scale
        cell.contentsScale = scale
    }

    /// The view moved to `window` (`viewDidMoveToWindow`).
    func place(in window: NSWindow?) {
        loops.place(in: window)
        if let window { setScale(window.backingScaleFactor) }
    }

    /// The view is shown in its window, not hidden or parked.
    func setShown(_ shown: Bool) {
        node.set(shown ? .visible : .hidden)
    }

    /// Main's turn after Ghostty presented cells (``TerminalCursorPresenter/present(_:)``): the blink follows the
    /// newest. A move or a new cell starts the blink again from shown, as Ghostty restarts its blink timer when the
    /// cursor changes. Nothing when no cell came since the last turn.
    func cellsDidChange() {
        guard let blink = presenter.takeBlink() else { return }
        self.blink = blink
        followBlink()
    }

    private func followBlink() {
        container.opacity = 1
        guard let blink, blink.wantsLoop else {
            motionWatch?.cancel()
            motionWatch = nil
            loops.detach(container, key: Self.blinkKey)
            return
        }
        if motionWatch == nil {
            motionWatch = motionSignals.subscribe([.motion], viewNode: node, owner: "TerminalCursorLayer") { [weak self] in
                self?.followBlink()
            }
        }
        let interval = blink.interval
        loops.attach(container, key: Self.blinkKey) { [weak self] in self?.makeBlink(interval: interval) }
    }

    /// One blink: shown for `interval`, hidden for `interval`, repeated; nil keeps the cursor steady. It
    /// begins shown at the moment it is made (``LoopVisibility`` adds it at the shared clock's phase, and the
    /// time offset takes that phase back), so a cursor that moved or showed again is seen at once.
    private func makeBlink(interval: TimeInterval) -> CAAnimation? {
        guard gate.policy.animatesBlinks else { return nil }
        let cycle = 2 * interval
        // motion: allow the period is the terminal's cursor blink interval (Ghostty's config), not a motion token; the indicators gate's animatesBlinks (master switch, category, Reduce Motion) decides whether it runs at all, and a change of those settings makes it again (motionWatch)
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
