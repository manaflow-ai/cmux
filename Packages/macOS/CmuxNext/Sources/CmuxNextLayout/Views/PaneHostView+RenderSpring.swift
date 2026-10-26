import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane host on a render-server spring (chrome-parity R2, p03-rendering-022a): its frame is at rest
/// from the spring's start, and additive springs of its backing layer show it moving there.
extension PaneHostView {
    /// The key paths a render-server spring of the host animates on its backing layer (each with its
    /// components: `RenderSpring.stop` takes `position.x` with `position`).
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// The host's frame is at rest and Core Animation shows it springing there (``springOnRenderServer``):
    /// it stays on its layout spring (``isOnLayoutSpring``) until the screen sees it land.
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }

    /// Moves the host to `move.to` (its superview's coordinates, alpha `move.toAlpha`) in this turn and lets
    /// the render server show it springing there from `move.from` at `move.velocity` (alpha `move.fromAlpha`)
    /// on `spring`: additive springs of its backing layer's position, size and opacity, so AppKit, hit tests
    /// and the content read the rest frame at once. The content hears its rest size before it takes it
    /// (``announceRest()``), and the frame is set once, to rest: the content resizes once and lays out
    /// once, at rest, with `laysOut`. A spring on a host already springing retargets: the springs still
    /// running keep their velocity. `landed` runs once, when this call's springs ended or a newer call
    /// took over (`RenderSpring.Completion`); the screen decides there whether the host left its layout
    /// spring (a CPU spring may still move it).
    func springOnRenderServer(_ move: SplitMotion.RenderMove, spring: RenderSpring, laysOut: Bool,
                              landed: @escaping @MainActor @Sendable () -> Void) {
        // On the render server before the frame moves: the content is never held (`contentFrame(in:)`).
        renderSpringsInFlight += 1
        restSize = move.to.size
        isOnLayoutSpring = true
        announceRest()
        frame = move.to
        alphaValue = move.toAlpha
        if laysOut { layoutSubtreeIfNeeded() }
        let finish: RenderSpring.Completion = { [weak self] _ in
            self?.renderSpringsInFlight -= 1
            landed()
        }
        guard let layer else {
            finish(true)
            return
        }
        var moves = renderSpringMoves(from: move.from, velocity: move.velocity)
        if move.fromAlpha != move.toAlpha { moves.append(RenderSpring.Move(layer, "opacity", from: move.fromAlpha, to: move.toAlpha)) }
        spring.animateGroup(moves, in: self, completion: finish)
    }
}
