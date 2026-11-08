public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens

/// The text swap (`TextSwapMotion`), the one way words change in place, ported from the webviews'
/// `useTextSwap` so a sidebar workspace's new name arrives as the agent chat's live line does (Leo
/// 2026-11-08: "when workspaces get renamed (esp by agents) it should have that same fade in
/// animation that the tool call situation has").
///
/// The old words are a snapshot layer laid over the view (inert: a layer takes no clicks and is no
/// accessibility element) that rises and fades out; the view's own layer, already showing the new
/// words, rises in under it. Only `opacity` and `transform` animate, and only as animations: the
/// view's frame and its layer's model values never change, so nothing lays out or moves around it.
///
/// Stop conditions: no timer and no frame loop. Each swap adds finite animations (at most
/// `standard` long) that end on their own; the snapshot leaves when its fade ends or is removed. The
/// next swap starts from where the words stand and keeps at most `MotionScale.textSwapMaxGhosts`
/// snapshots; `cancelTextSwap(in:)` (a recycled row) ends it at once.
extension MotionGate {
    /// The snapshot layer's name, over the view in its superview's layer.
    public static let textSwapGhostName = "cmux.textSwap.ghost"
    /// The view layer's animation keys while the new words arrive.
    public static let textSwapOpacityKey = "cmux.textSwap.opacity"
    public static let textSwapRiseKey = "cmux.textSwap.rise"
    /// The snapshot's animation key.
    static let textSwapOutKey = "cmux.textSwap.out"
    /// The snapshot's owner (the view's layer), so two views in one superview keep apart.
    static let textSwapOwnerKey = "cmux.textSwap.owner"

    /// Changes the words `view` shows (`change` sets them) with the text swap, or in one frame when this
    /// gate's motion is off, `view`'s window cannot animate (``Motion/canAnimate(in:)``) or it has no
    /// layer, superlayer or size to snapshot. True when the swap plays.
    ///
    /// The caller decides that this is a real change of words the person was reading; first paint,
    /// restore and a row scrolled into view set the words directly.
    @discardableResult
    @MainActor public func swapText(in view: NSView, _ change: () -> Void) -> Bool {
        guard let layer = view.layer, let superlayer = layer.superlayer, let window = view.window,
              canAnimate(in: view), let motion = TextSwapMotion(policy: policy), !view.bounds.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            cancelTextSwap(in: view)
            change()
            return false
        }
        // The old words as they read: the snapshot draws the model (full opacity, at rest); where they
        // stand on screen now (partway in from an earlier swap) is where the snapshot starts.
        view.cacheDisplay(in: view.bounds, to: rep)
        let down = Self.textSwapDown(in: view)
        let shown = layer.presentation()
        let start = TextSwapMotion.Pose(
            opacity: Double(shown?.opacity ?? layer.opacity),
            y: motion.style == .rise ? Double((shown?.transform.m42 ?? 0) / down) : 0)
        let curve = CAMediaTimingFunction(controlPoints: MotionScale.easeOut.0, MotionScale.easeOut.1,
                                          MotionScale.easeOut.2, MotionScale.easeOut.3)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.removeAnimation(forKey: Self.textSwapOpacityKey)
        layer.removeAnimation(forKey: Self.textSwapRiseKey)
        // Oldest first: the ones past the cap (with the new one) go, the newest stay.
        var ghosts = Self.textSwapGhosts(of: layer)
        for ghost in ghosts.prefix(max(0, ghosts.count - (MotionScale.textSwapMaxGhosts - 1))) {
            ghost.removeAllAnimations()
            ghost.removeFromSuperlayer()
        }
        ghosts = Self.textSwapGhosts(of: layer)
        change()

        let ghost = CALayer()
        ghost.name = Self.textSwapGhostName
        ghost.setValue(layer, forKey: Self.textSwapOwnerKey)
        // Exactly over the view, about the same anchor (a view's layer anchors at its corner).
        ghost.anchorPoint = layer.anchorPoint
        ghost.bounds = layer.bounds
        ghost.position = layer.position
        ghost.contents = rep.cgImage
        ghost.contentsGravity = .resize
        ghost.contentsScale = window.backingScaleFactor
        // Its end state as the model: when the fade ends the snapshot is already invisible.
        let end = motion.outgoing(at: motion.outDuration, from: start)
        ghost.opacity = Float(end.opacity)
        ghost.transform = CATransform3DMakeTranslation(0, CGFloat(end.y) * down, 0)
        // Above the newest snapshot (else the view), so the snapshots stand oldest first in the superlayer.
        superlayer.insertSublayer(ghost, above: ghosts.last ?? layer)

        let leaving: CAAnimation
        switch motion.style {
        case .rise:
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [start.opacity, 0, 0]
            fade.keyTimes = [0, NSNumber(value: TextSwapMotion.goneAt), 1]
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = CGFloat(start.y) * down
            lift.toValue = CGFloat(-TextSwapMotion.rise) * down
            // A group's children keep their own duration (0.25 s when unset) and the group clips them: each spans
            // the whole out duration, so the fade is gone at `goneAt` of it, as `useTextSwap.ts`'s keyframes are.
            (fade.duration, lift.duration) = (motion.outDuration, motion.outDuration)
            let group = CAAnimationGroup()
            group.animations = [fade, lift]
            leaving = group
        case .crossfade:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = start.opacity
            fade.toValue = 0
            leaving = fade
        }
        leaving.duration = motion.outDuration
        leaving.timingFunction = curve
        CATransaction.begin()
        // Removed when its fade ends or is cut short (the next swap, `cancelTextSwap`), as SidebarRevealFlash removes
        // its layer: the animation is still attached when the block runs, so the block does not ask it.
        CATransaction.setCompletionBlock { [weak ghost] in ghost?.removeFromSuperlayer() }
        ghost.add(leaving, forKey: Self.textSwapOutKey)
        CATransaction.commit()

        let arriving = CAKeyframeAnimation(keyPath: "opacity")
        switch motion.style {
        case .rise:
            arriving.values = [0, 0, 1]
            arriving.keyTimes = [0, NSNumber(value: TextSwapMotion.showFrom), 1]
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = CGFloat(TextSwapMotion.rise) * down
            lift.toValue = 0
            lift.duration = motion.inDuration
            lift.timingFunction = curve
            layer.add(lift, forKey: Self.textSwapRiseKey)
        case .crossfade:
            arriving.values = [0, 1]
            arriving.keyTimes = [0, 1]
        }
        arriving.duration = motion.inDuration
        arriving.timingFunction = curve
        layer.add(arriving, forKey: Self.textSwapOpacityKey)
        return true
    }

    /// Ends `view`'s swap at once: the new words show at rest and the old ones go.
    @MainActor public func cancelTextSwap(in view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.textSwapOpacityKey)
        layer.removeAnimation(forKey: Self.textSwapRiseKey)
        for ghost in Self.textSwapGhosts(of: layer) {
            ghost.removeAllAnimations()
            ghost.removeFromSuperlayer()
        }
    }

    /// The snapshots over `layer`, oldest first (`swapText` puts each new one above the last).
    @MainActor static func textSwapGhosts(of layer: CALayer) -> [CALayer] {
        (layer.superlayer?.sublayers ?? []).filter {
            $0.name == textSwapGhostName && ($0.value(forKey: textSwapOwnerKey) as AnyObject?) === layer
        }
    }

    /// 1 when +y in `view`'s superview's layer runs down the screen, else -1: the sign a downward offset
    /// (`TextSwapMotion.Pose.y`) takes in the view layer's transform, whatever the views' flipping.
    @MainActor static func textSwapDown(in view: NSView) -> CGFloat {
        guard let parent = view.superview else { return view.isFlipped ? 1 : -1 }
        let origin = parent.convert(parent.convertFromLayer(NSPoint.zero), to: nil)
        let below = parent.convert(parent.convertFromLayer(NSPoint(x: 0, y: 1)), to: nil)
        // Window coordinates run up the screen.
        return below.y < origin.y ? 1 : -1
    }
}
