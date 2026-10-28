import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane host on a render-server spring (chrome-parity R2): its frame is at rest
/// from the spring's start, and additive springs of its backing layer show it moving there.
extension PaneHostView {
    /// The key paths a render-server spring of the host animates on its backing layer (each with its
    /// components: `RenderSpring.stop` takes `position.x` with `position`).
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// The host's frame is at rest and Core Animation shows it springing there (``springToRest(_:spring:inPlane:landed:)``):
    /// it stays on its layout spring (``isOnLayoutSpring``) until the screen sees it land.
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }

    /// Moves the host to `move.to` (its superview's coordinates, alpha `move.toAlpha`) in this turn, the
    /// first half of a render-server spring: the content hears its rest size before it takes it
    /// (``announceRest()``), and the frame is set once, to rest, so the content resizes once and lays out
    /// once, at rest, with `laysOut`. Every call is followed in the same turn by one
    /// ``springToRest(_:spring:inPlane:landed:)``, after the plane placed the host's chrome at rest
    /// (`LayoutViewContext.overlaySyncNow`).
    func placeAtRest(_ move: SplitMotion.RenderMove, laysOut: Bool) {
        // On the render server before the frame moves: the content is never held (`contentFrame(in:)`), and a
        // page in its own window hides while the frame still shows where it was (`showsRenderMove`).
        renderSpringsInFlight += 1
        if move.from != move.to || !move.velocity.isZero { showsRenderMove = true }
        restSize = move.to.size
        isOnLayoutSpring = true
        announceRest()
        frame = move.to
        alphaValue = move.toAlpha
        // sync-layout: the content lays out once, at rest, before the overlay plane's sync places the chrome from it.
        if laysOut { layoutSubtreeIfNeeded() }
    }

    /// Lets the render server show the host, placed at rest by ``placeAtRest(_:laysOut:)``, springing there
    /// from `move.from` at `move.velocity` (alpha `move.fromAlpha`) on `spring`: additive springs of its
    /// backing layer's position, size and opacity, so AppKit, hit tests and the content read the rest frame
    /// at once. Its chrome rides in the same group (``PaneOverlayView/rideMoves(from:velocity:fromAlpha:toAlpha:)``),
    /// one token and one begin time, so ring and dim edges stay on the pane's; `inPlane` converts a rect of a
    /// view to the overlay plane's coordinates (`LayoutViewContext.overlayPlaneRect`). A spring on a host already
    /// springing retargets: the springs still running keep their velocity. `landed` runs once, when this
    /// call's springs ended or a newer call took over (`RenderSpring.Completion`); the screen decides there
    /// whether the host left its layout spring (a CPU spring may still move it).
    func springToRest(_ move: SplitMotion.RenderMove, spring: RenderSpring, inPlane: (CGRect, NSView) -> CGRect?,
                      landed: @escaping @MainActor @Sendable () -> Void) {
        let finish: RenderSpring.Completion = { [weak self] _ in
            if let self {
                renderSpringsInFlight -= 1
                if renderSpringsInFlight == 0 {
                    chrome.rideEnded()
                    showsRenderMove = false
                }
            }
            landed()
        }
        guard let layer else {
            finish(true)
            return
        }
        var moves = renderSpringMoves(from: move.from, velocity: move.velocity)
        if move.fromAlpha != move.toAlpha { moves.append(RenderSpring.Move(layer, .opacity, from: move.fromAlpha, to: move.toAlpha)) }
        // The chrome is off this rest only when the plane placed nothing (a root that is not live, a hidden host).
        var rides = false
        if let superview, let rest = inPlane(bounds, self), Self.gap(rest, chrome.frame) < 0.01,
           let start = Self.converted(move.from, velocity: move.velocity, from: superview, by: inPlane) {
            moves += chrome.rideMoves(from: start.rect, velocity: start.velocity, fromAlpha: move.fromAlpha, toAlpha: move.toAlpha)
            rides = true
        }
        spring.animateGroup(moves, in: self, completion: finish)
        // The rings' sizes spring now; their glows' outlines follow them.
        if rides { chrome.followRideShadows() }
    }

    /// `rect`, moving at `velocity`, in `view`'s coordinates, in the coordinates `convert` maps a rect of
    /// `view` to (the overlay plane's): a real conversion, so a canvas camera's zoom scales the chrome's start
    /// and its velocity as it scales the host. Nil when `convert` has no answer.
    static func converted(_ rect: CGRect, velocity: RectComponents, from view: NSView,
                          by convert: (CGRect, NSView) -> CGRect?) -> (rect: CGRect, velocity: RectComponents)? {
        guard let shown = convert(rect, view), let origin = convert(.zero, view),
              let unitX = convert(CGRect(x: 1, y: 0, width: 0, height: 0), view),
              let unitY = convert(CGRect(x: 0, y: 1, width: 0, height: 0), view) else { return nil }
        let axes = RenderLayerAxes(x: unitX.minX - origin.minX, y: unitY.minY - origin.minY)
        let rate = axes.velocity(velocity, anchor: .zero)
        return (shown, RectComponents(x: rate.position.x, y: rate.position.y, width: rate.size.width, height: rate.size.height))
    }

    /// The largest gap between two rects' edges and sizes.
    private static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// On a render-server spring the frame is at rest and Core Animation draws the host elsewhere
    /// (``isOnRenderSpring``): a press takes the host where it is drawn, at the same place of its content
    /// (``restPoint(ofDrawn:)``). At rest no presentation layer is read.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // A hidden view takes no press (NSView's rule), on a spring or not.
        guard !isHidden else { return nil }
        var point = point
        let springing = isOnRenderSpring
        if springing {
            guard let rest = restPoint(ofDrawn: point) else { return nil }
            point = rest
        }
        if let areaHitClip, !areaHitClip.contains(convert(point, from: superview)) { return nil }
        // Drawn larger than its rest, the host's own fill takes what its content does not reach, while it shows.
        return super.hitTest(point) ?? (springing && alphaValue > 0 ? self as NSView : nil)
    }

    /// `point` (superview coordinates) where the render server draws the host now, moved to the same place
    /// of the host at rest; nil outside what it draws (its layer clips to its bounds). The content rides the
    /// host's origin corner, its top left: the smaller y, since its superview (the screen or the strip
    /// container, ``ScreenContentView/hostParent(for:)``) is flipped. Chromium routes input by the transforms of the frames viz drew the
    /// same way (`components/viz/host/hit_test/hit_test_query.cc`, `HitTestQuery::FindTargetForLocation`).
    func restPoint(ofDrawn point: CGPoint) -> CGPoint? {
        guard let layer, let superview else { return point }
        presentedHitReads += 1
        guard let drawn = layer.presentation() else { return point }
        let shown = superview.convertFromLayer(drawn.frame), rest = superview.convertFromLayer(layer.frame)
        guard shown.contains(point) else { return nil }
        return CGPoint(x: point.x + rest.minX - shown.minX, y: point.y + rest.minY - shown.minY)
    }

    /// The host's position and size springs end, its chrome's with them (a fade runs on): its CPU frame
    /// takes what shows (`ScreenContentView.takeRenderSpringsBack`).
    func stopRenderMoves() {
        if let layer { ScreenContentView.stopMoveSprings(layer) }
        chrome.stopRide()
        showsRenderMove = false
    }
}
