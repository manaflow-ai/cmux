import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane host on a render-server spring (chrome-parity R2, p03-rendering-022a): its frame is at rest
/// from the spring's start, and additive springs of its backing layer show it moving there.
extension PaneHostView {
    /// The key paths a render-server spring of the host animates on its backing layer (each with its
    /// components: `RenderSpring.stop` takes `position.x` with `position`).
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// The host's frame is at rest and Core Animation shows it springing there (``springToRest(_:spring:landed:)``):
    /// it stays on its layout spring (``isOnLayoutSpring``) until the screen sees it land.
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }

    /// Moves the host to `move.to` (its superview's coordinates, alpha `move.toAlpha`) in this turn, the
    /// first half of a render-server spring: the content hears its rest size before it takes it
    /// (``announceRest()``), and the frame is set once, to rest, so the content resizes once and lays out
    /// once, at rest, with `laysOut`. Every call is followed in the same turn by one
    /// ``springToRest(_:spring:landed:)``, after the plane placed the host's chrome at rest
    /// (`LayoutViewContext.overlaySyncNow`).
    func placeAtRest(_ move: SplitMotion.RenderMove, laysOut: Bool) {
        // On the render server before the frame moves: the content is never held (`contentFrame(in:)`).
        renderSpringsInFlight += 1
        restSize = move.to.size
        isOnLayoutSpring = true
        announceRest()
        frame = move.to
        alphaValue = move.toAlpha
        if laysOut { layoutSubtreeIfNeeded() }
    }

    /// Lets the render server show the host, placed at rest by ``placeAtRest(_:laysOut:)``, springing there
    /// from `move.from` at `move.velocity` (alpha `move.fromAlpha`) on `spring`: additive springs of its
    /// backing layer's position, size and opacity, so AppKit, hit tests and the content read the rest frame
    /// at once. Its chrome rides in the same group (``PaneOverlayView/rideMoves(from:velocity:fromAlpha:toAlpha:)``),
    /// one token and one begin time, so ring and dim edges stay on the pane's. A spring on a host already
    /// springing retargets: the springs still running keep their velocity. `landed` runs once, when this
    /// call's springs ended or a newer call took over (`RenderSpring.Completion`); the screen decides there
    /// whether the host left its layout spring (a CPU spring may still move it).
    func springToRest(_ move: SplitMotion.RenderMove, spring: RenderSpring, landed: @escaping @MainActor @Sendable () -> Void) {
        let finish: RenderSpring.Completion = { [weak self] _ in
            if let self {
                renderSpringsInFlight -= 1
                if renderSpringsInFlight == 0 { chrome.rideEnded() }
            }
            landed()
        }
        guard let layer else {
            finish(true)
            return
        }
        var moves = renderSpringMoves(from: move.from, velocity: move.velocity)
        if move.fromAlpha != move.toAlpha { moves.append(RenderSpring.Move(layer, "opacity", from: move.fromAlpha, to: move.toAlpha)) }
        // The plane placed the chrome on this rest frame, in the root's coordinates: the same shift carries `from` there.
        if abs(chrome.frame.width - frame.width) < 0.01, abs(chrome.frame.height - frame.height) < 0.01 {
            let from = move.from.offsetBy(dx: chrome.frame.minX - frame.minX, dy: chrome.frame.minY - frame.minY)
            moves += chrome.rideMoves(from: from, velocity: move.velocity, fromAlpha: move.fromAlpha, toAlpha: move.toAlpha)
        }
        spring.animateGroup(moves, in: self, completion: finish)
    }

    /// The host's position and size springs end, its chrome's with them (a fade runs on): its CPU frame
    /// takes what shows (`ScreenContentView.takeRenderSpringsBack`).
    func stopRenderMoves() {
        if let layer { ScreenContentView.stopMoveSprings(layer) }
        chrome.stopRide()
    }
}
