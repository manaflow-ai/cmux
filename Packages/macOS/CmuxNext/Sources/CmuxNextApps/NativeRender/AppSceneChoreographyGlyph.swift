import AppKit
import CmuxNextDesign

/// Draws a `Particles {choreography}` document (``AppSceneChoreography``) as the web renderer does
/// (`webviews/src/apps/scene/choreographyGlyph.ts`): one layer per dot, up to the document's `max`,
/// moved only by its `transform` (translate and scale about the glyph's centre), with implicit
/// actions off, so a frame never lays out or draws anything.
///
/// The dots step on the window's one ``MotionClock`` (the clock every spring of the window steps on),
/// gated by ``Motion/appScenes``: they move only while loops run there (the master switch, the
/// indicators switch, `ui.animationSpeed` not off, no Reduce Motion), and player time runs at
/// `ui.animationSpeed`'s time scale, as the web's. With loops off the glyph holds its still (the first
/// frame of what would play) and asks for no frames. A window out of sight gets no frames (the
/// scheduler settles the clock): the dots hold where they are until the owner's occlusion observer
/// calls ``update(in:)`` again.
final class AppSceneChoreographyGlyph: MotionAnimating {
    /// A zero-size layer at the centre of the node's frame; each dot is a sublayer on it.
    let host = CALayer()
    /// The dot layers, `choreography.max` of them once laid out.
    private(set) var dots: [CALayer] = []
    /// The `choreography` prop this glyph plays (a new value builds a new glyph).
    let document: AppJSON
    private(set) var player: AppSceneChoreography.Player
    /// Player time (ms): elapsed frame time divided by `ui.animationSpeed`'s time scale.
    private(set) var playerTime: Double = 0
    private var dotSize: CGFloat = 0
    private var color: CGColor?
    private weak var clock: MotionClock?
    /// What each dot layer shows now, so a still frame sets nothing.
    private var shown: [AppSceneChoreography.Dot?] = []

    /// The layer actions that would animate a dot between frames: none of them run.
    private static let noActions: [String: any CAAction] = [
        "transform": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "backgroundColor": NSNull(), "cornerRadius": NSNull(), "sublayers": NSNull(),
    ]

    init(document: AppJSON, choreography: AppSceneChoreography, request: AppSceneChoreography.Request) {
        self.document = document
        player = AppSceneChoreography.Player(choreography, request: request, now: 0)
        host.actions = Self.noActions
        host.bounds = .zero
    }

    var choreography: AppSceneChoreography { player.choreography }

    /// Whether the clock steps the dots now.
    var isRunning: Bool { clock?.isRunning(self) ?? false }

    /// What the node asks for (`trigger`, `phase`); the player reads it when its phase ends.
    func setRequest(_ request: AppSceneChoreography.Request) {
        player.setRequest(request)
    }

    /// Puts the glyph's centre at `center` (the superlayer's coordinates) with dots `size` points
    /// square, building the dot layers on first use.
    func layout(center: CGPoint, size: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.position = center
        if dots.count != choreography.max {
            for dot in dots { dot.removeFromSuperlayer() }
            dots = (0..<choreography.max).map { _ in
                let dot = CALayer()
                dot.actions = Self.noActions
                dot.isHidden = true
                host.addSublayer(dot)
                return dot
            }
            shown = Array(repeating: nil, count: dots.count)
            dotSize = 0
        }
        if size != dotSize {
            dotSize = size
            for dot in dots {
                dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                dot.position = .zero
                dot.cornerRadius = choreography.shape == .circle ? size / 2 : 0
                dot.backgroundColor = color
            }
        }
        // The superlayer's flip may have changed with the move: place the dots again.
        shown = Array(repeating: nil, count: dots.count)
        place(isRunning ? player.sample(playerTime) : currentStill())
    }

    /// Colors every dot (read in the view's theme scope).
    func paint(color: CGColor) {
        guard color != self.color else { return }
        self.color = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    /// Starts the clock in `view`'s window when the app-scene gate runs loops there; otherwise stops
    /// it, and with loops off holds the still.
    func update(in view: NSView) {
        guard view.window != nil else { return stop() }
        guard Motion.appScenes.animatesLoops else {
            stop()
            place(player.still())
            return
        }
        let target = MotionClock.forView(view)
        if let clock, clock !== target { clock.stop(self) }
        clock = target
        guard !target.isRunning(self) else { return }
        place(player.sample(playerTime))
        target.run(self, trace: "appScene.choreography")
    }

    /// Stops the clock; the dots hold where they are.
    func stop() {
        clock?.stop(self)
    }

    /// What shows when the clock does not run: the still with loops off, else where the dots are.
    private func currentStill() -> [AppSceneChoreography.Dot] {
        Motion.appScenes.animatesLoops ? player.sample(playerTime) : player.still()
    }

    func motionStep(_ dt: Double) -> Bool { // perf-hot: 4ms motion-frame
        guard Motion.appScenes.animatesLoops else {
            place(player.still())
            return false
        }
        let scale = Motion.appScenes.speed.timeScale
        // A long gap between frames (a stall, the first frame after a pause) moves at most a quarter
        // second; the player restarts its program past a minute either way.
        if scale > 0 { playerTime += min(max(dt, 0), 0.25) * 1000 / scale }
        place(player.sample(playerTime))
        return true
    }

    /// The window went out of sight: the dots hold where they are (the web pauses a glyph off
    /// screen the same way). The default settle would step twenty seconds of a loop that never rests.
    func motionSettle() {}

    /// Sets each dot layer's transform for `dots` (a dot past the list, or of scale 0, hides).
    private func place(_ dots: [AppSceneChoreography.Dot]) {
        guard !self.dots.isEmpty else { return }
        // +y is down in the document; flip into the host's space when its geometry is not flipped.
        let down: CGFloat = host.contentsAreFlipped() ? 1 : -1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in self.dots.enumerated() {
            let dot = index < dots.count && dots[index].s > 0 ? dots[index] : nil
            guard index >= shown.count || shown[index] != dot else { continue }
            if index < shown.count { shown[index] = dot }
            guard let dot else {
                layer.isHidden = true
                continue
            }
            let scale = CGFloat(dot.s)
            let moved = CATransform3DMakeTranslation(CGFloat(dot.x), CGFloat(dot.y) * down, 0)
            layer.transform = CATransform3DScale(moved, scale, scale, 1)
            layer.isHidden = false
        }
        CATransaction.commit()
    }
}
