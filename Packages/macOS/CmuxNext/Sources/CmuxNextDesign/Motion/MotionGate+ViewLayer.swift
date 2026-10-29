public import AppKit
import QuartzCore
public import CmuxNextDesignTokens

/// A layer-backed view's frame and alpha moved on the render server.
///
/// The view's `frame` and `alphaValue` take their targets once, in the call's turn, so hit testing,
/// layout, tracking areas and the next change read the rest values. Its layer then shows the change
/// with additive animations (``RenderSpring``) from the old values, so the main thread writes nothing
/// per frame (rule 1, plans/cmux-next/chrome-parity/p03-rendering.md). An `animator()` change in a
/// SwiftUI-animation `NSAnimationContext` (the closure `animate(_:in:_:completion:)`) is AppKit's to
/// step instead; MotionGateMainWorkTests records what it writes per frame.
///
/// Chrome's model: a `views::View`'s bounds and opacity animations run on its `ui::Layer` in the
/// compositor while the view already holds its target bounds (ui/compositor/layer_animator.h,
/// ui/views/animation/bounds_animator.h).
///
/// A size change moves the view's own layer only: the layers of its subviews show their rest frames
/// (rule 4). A view with no layer, or whose layer is not in its superview's layer, has nothing to show
/// the move on: its change is on screen in this frame and `completion` runs now.
extension MotionGate {
    /// Springs `view` to `frame` and `alpha` with `token` (nil leaves one as it is; `frame` is never
    /// defaulted, so the call cannot read as the closure `animate(_:in:_:completion:)`). With movement off
    /// the frame changes in one frame and the alpha crossfades (a Reduce Motion crossfade) or changes in
    /// one frame. `completion` runs when the view lands (``RenderSpring/Completion``).
    public func animate(_ token: MotionSpring, in view: NSView, frame: NSRect?, alpha: CGFloat? = nil,
                        completion: RenderSpring.Completion? = nil) {
        let spring = renderSpring(token)
        // One outer transaction: the rest values and their animations commit together.
        CATransaction.begin()
        let moves = Self.restMoves(of: view, frame: frame, alpha: alpha)
        let shown = canAnimate(in: view)
        let styles = moves.map { spring.style(for: $0.keyPath, shown: shown) }
        Self.run(moves, styles: styles, trace: "render.\(token.rawValue)", completion: completion)
        CATransaction.commit()
    }

    /// Moves `view` to `frame` and fades it to `alpha` over `token`'s duration on the fade curve (nil
    /// leaves one as it is). The frame changes in one frame when movement does not animate (Reduce
    /// Motion, motion.md rule 7); the alpha when fades do not. `completion` runs when the view lands
    /// (``RenderSpring/Completion``).
    public func animate(_ token: MotionFade, in view: NSView, frame: NSRect?, alpha: CGFloat? = nil,
                        completion: RenderSpring.Completion? = nil) {
        let seconds = canAnimate(in: view) ? duration(token) : 0
        CATransaction.begin()
        let moves = Self.restMoves(of: view, frame: frame, alpha: alpha)
        let styles = moves.map { move -> RenderSpring.Style in
            seconds > 0 && (RenderSpring.isFade(move.keyPath) || animatesMovement) ? .timed(seconds) : .snap
        }
        Self.run(moves, styles: styles, trace: "render.\(token.rawValue)", completion: completion)
        CATransaction.commit()
    }

    /// Runs `moves` in `styles` and marks motion in flight (``MotionActivity``) for the longest change that
    /// runs: a spring-token crossfade with movement off counts its crossfade, not the spring's 0.
    private static func run(_ moves: [RenderSpring.Move], styles: [RenderSpring.Style], trace: String,
                            completion: RenderSpring.Completion?) {
        MotionActivity.began(seconds: styles.map(\.seconds).max() ?? 0)
        RenderSpring.run(moves, styles: styles, trace: trace, completion: completion)
    }

    /// Writes `view`'s frame and alpha at their targets and returns the moves its layer shows the change
    /// by, from the old values (the layer's rest values offset as `NSView+RenderMove` does in CmuxNextLayout).
    /// Empty when nothing changed or the view has no layer in its superview's layer.
    private static func restMoves(of view: NSView, frame: NSRect?, alpha: CGFloat?) -> [RenderSpring.Move] {
        let oldFrame = view.frame, oldAlpha = view.alphaValue
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let frame, frame != oldFrame { view.frame = frame }
        if let alpha, alpha != oldAlpha { view.alphaValue = alpha }
        CATransaction.commit()
        guard let layer = view.layer else { return [] }
        var moves: [RenderSpring.Move] = []
        if view.frame != oldFrame, let superview = view.superview, layer.superlayer === superview.layer {
            let start = superview.convertToLayer(oldFrame), rest = superview.convertToLayer(view.frame)
            let anchor = layer.anchorPoint
            let position = layer.position, size = layer.bounds.size
            let shift = CGPoint(x: start.minX - rest.minX + anchor.x * (start.width - rest.width),
                                y: start.minY - rest.minY + anchor.y * (start.height - rest.height))
            if shift != .zero {
                moves.append(RenderSpring.Move(layer, .position, from: CGPoint(x: position.x + shift.x, y: position.y + shift.y), to: position))
            }
            if start.size != rest.size {
                let from = CGSize(width: size.width + start.width - rest.width, height: size.height + start.height - rest.height)
                moves.append(RenderSpring.Move(layer, .boundsSize, from: from, to: size))
            }
        }
        if view.alphaValue != oldAlpha {
            moves.append(RenderSpring.Move(layer, .opacity, from: oldAlpha, to: view.alphaValue))
        }
        return moves
    }
}
