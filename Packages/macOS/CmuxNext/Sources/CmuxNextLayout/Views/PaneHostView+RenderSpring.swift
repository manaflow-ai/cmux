import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane host on a render-server spring (chrome-parity R2, p03-rendering-022a): its frame is at rest
/// from the spring's start, and additive springs of its backing layer show it moving there.
extension PaneHostView {
    /// The key paths a render-server spring of the host animates on its backing layer.
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// The host's frame is at rest and Core Animation shows it springing there (``springOnRenderServer``):
    /// it stays on its layout spring (``isOnLayoutSpring``) until the last spring lands.
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }

    /// Moves the host to `rest` (its superview's coordinates, alpha `restAlpha`) in this turn and lets the render
    /// server show it springing there from `from` (alpha `fromAlpha`) on `spring`: additive springs of its
    /// backing layer's position, size and opacity, so AppKit, hit tests and the content read the rest frame
    /// at once. The content hears its rest size before it takes it (``announceRest()``) and lays out once,
    /// at rest, with `laysOut`. A spring on a host already springing retargets: the springs still running
    /// keep their velocity. `landed` runs once, when this call's springs ended or a newer call took over
    /// (`RenderSpring.Completion`); the host leaves its layout spring when its last call lands.
    func springOnRenderServer(from: CGRect, alpha fromAlpha: CGFloat, to rest: CGRect, alpha restAlpha: CGFloat,
                              spring: RenderSpring, laysOut: Bool, landed: @escaping @MainActor @Sendable () -> Void) {
        // On the render server before the frame moves: the content is never held (`contentFrame(in:)`).
        renderSpringsInFlight += 1
        restSize = rest.size
        isOnLayoutSpring = true
        // AppKit maps the frame to the layer: the springs start from the layer geometry it writes for `from`.
        frame = from
        let start = (position: layer?.position ?? .zero, size: layer?.bounds.size ?? .zero)
        announceRest()
        frame = rest
        alphaValue = restAlpha
        if laysOut { layoutSubtreeIfNeeded() }
        let finish: RenderSpring.Completion = { [weak self] _ in
            self?.renderSpringLanded()
            landed()
        }
        guard let layer else {
            finish(true)
            return
        }
        var moves = [RenderSpring.Move(layer, "position", from: start.position, to: layer.position),
                     RenderSpring.Move(layer, "bounds.size", from: start.size, to: layer.bounds.size)]
        if fromAlpha != restAlpha { moves.append(RenderSpring.Move(layer, "opacity", from: fromAlpha, to: restAlpha)) }
        spring.animateGroup(moves, in: self, completion: finish)
    }

    /// One render-server spring call landed: after the last, the host is at rest (its one clip layout, then
    /// the content hears it landed, ``isOnLayoutSpring``).
    private func renderSpringLanded() {
        renderSpringsInFlight -= 1
        if renderSpringsInFlight == 0 { isOnLayoutSpring = false }
    }
}
