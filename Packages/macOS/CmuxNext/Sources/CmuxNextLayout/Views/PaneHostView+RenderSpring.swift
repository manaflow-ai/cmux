import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane chrome's render-server spring, set with its host's and started by the overlay sync that puts the
/// chrome at the host's rest frame (`LayoutRootView.syncOverlay`): the host's offset off its rest, velocity,
/// token and begin time, so the ring and dim stay on the pane they draw over.
struct PaneChromeSpring {
    var offset: FrameDelta
    var velocity: FrameDelta
    var spring: RenderSpring
    /// The media time the host's springs began at.
    var begin: CFTimeInterval
}

/// A pane host on a render-server spring (chrome-parity R2, p03-rendering-022a): its frame is at rest
/// from the spring's start, and additive springs of its backing layer show it moving there.
extension PaneHostView {
    /// The key paths a render-server spring of the host (or of its chrome) animates, and their components.
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// The host's frame is at rest and Core Animation shows it springing there (``springOnRenderServer``):
    /// it stays on its layout spring (``isOnLayoutSpring``) until the last spring lands.
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }

    /// Moves the host to `move.to` (its superview's coordinates) in this turn and lets the render server show
    /// it springing there from `move.offset` off it at `move.velocity`, on `spring` from the media time `begin`:
    /// scalar additive springs of its backing layer's position and size, so AppKit, hit tests and the content
    /// read the rest frame at once. The content hears its rest size (`restSize`, the unrounded rest the
    /// screen's presentation also reads) while it still has its old one (``announceRest()``), and then lays
    /// out once, at rest: the view's frame is written once. A spring on a host already springing retargets:
    /// the springs still running keep their velocity. `call` lands when this call's springs end or a newer
    /// call takes over; the host leaves its layout spring when its last call lands.
    func springOnRenderServer(_ move: RenderMove, restSize: CGSize, spring: RenderSpring, begin: CFTimeInterval,
                              laysOut: Bool, call: RenderSpringCall) {
        // On the render server before the frame moves: the content is never held (`contentFrame(in:)`).
        renderSpringsInFlight += 1
        self.restSize = restSize
        isOnLayoutSpring = true
        announceRest()
        if frame != move.to { frame = move.to }
        if alphaValue != move.toAlpha { alphaValue = move.toAlpha }
        if laysOut { layoutSubtreeIfNeeded() }
        guard let layer, let superview else { return call.land() }
        if window != nil { chromeSpring = PaneChromeSpring(offset: move.offset, velocity: move.velocity, spring: spring, begin: begin) }
        var moves = layer.springMoves(offset: move.offset, velocity: move.velocity, flipsY: superview.layerFlipsY)
        if move.fromAlpha != move.toAlpha { moves.append(RenderSpring.Move(layer, "opacity", from: move.fromAlpha, to: move.toAlpha)) }
        spring.animateGroup(moves, in: self, startingAt: begin) { _ in call.land() }
    }

    /// One render-server spring call landed. After the last, the host is at rest (its one clip layout, then the
    /// content hears it landed, ``isOnLayoutSpring``), unless `settles` is false: the CPU step moves it on.
    func renderSpringLanded(settles: Bool) {
        renderSpringsInFlight -= 1
        guard renderSpringsInFlight == 0 else { return }
        chromeSpring = nil
        if settles { isOnLayoutSpring = false }
    }

    /// Takes the render-server springs off the host and its chrome: each shows its model frame now.
    func stopRenderSprings() {
        chromeSpring = nil
        if let layer { for keyPath in Self.renderSpringKeyPaths { RenderSpring.stop(layer, keyPath) } }
        chrome.stopRenderSprings()
    }
}
