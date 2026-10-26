public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens

/// Moves a view's visible width with no layout: a mask layer on the view's
/// layer shows its leading points, and the mask's width springs on the
/// render server (`RenderSpring`, additive). The view keeps its laid-out
/// frame for the whole change, as Chromium animates a clip rect on the
/// compositor instead of laying views out per frame
/// (ui/compositor/layer_animation_element.cc, `CreateClipRectElement`).
/// The mask is its own layer, never one AppKit rewrites.
@MainActor
public protocol RenderClipMotion: AnyObject {
    /// Whether a change of `view` animates now (the gate's movement policy and a screen to run on).
    func animates(in view: NSView) -> Bool
    /// Shows the leading `width` points of `view`. `start` places a new clip
    /// first; nil continues from what the running clip shows (the additive
    /// retarget keeps the presented width and its velocity). `completion`
    /// runs once, when this change's spring settles.
    func clip(_ view: NSView, from start: CGFloat?, to width: CGFloat, token: MotionSpring,
              completion: @escaping @MainActor @Sendable () -> Void)
    /// Removes the clip: the view shows whole.
    func unclip(_ view: NSView)
}

/// The render-server ``RenderClipMotion`` of one motion gate.
@MainActor
public final class RenderClip: RenderClipMotion {
    private let gate: MotionGate
    /// Names the clip's mask, so the view's own layer is the only record of it.
    static let maskName = "cmux.renderClip"

    public init(gate: MotionGate) {
        self.gate = gate
    }

    public func animates(in view: NSView) -> Bool {
        gate.policy.animatesMovement && gate.canAnimate(in: view)
    }

    public func clip(_ view: NSView, from start: CGFloat?, to width: CGFloat, token: MotionSpring,
                     completion: @escaping @MainActor @Sendable () -> Void) {
        view.wantsLayer = true
        guard let host = view.layer else { return completion() }
        let current = host.mask.flatMap { $0.name == Self.maskName ? $0 : nil }
        let mask = current ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if current == nil {
            mask.name = Self.maskName
            mask.backgroundColor = NSColor.black.cgColor
            mask.anchorPoint = .zero
            mask.position = .zero
            host.mask = mask
        }
        mask.bounds.size.height = host.bounds.height
        if let start { mask.bounds.size.width = start }
        CATransaction.commit()
        // The landing is this transaction's completion: it runs once the spring it adds settles.
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        _ = RenderSpring.animate(mask, keyPath: "bounds.size.width", to: width, token: token, gate: gate)
        CATransaction.commit()
    }

    public func unclip(_ view: NSView) {
        guard let host = view.layer, let mask = host.mask, mask.name == Self.maskName else { return }
        mask.removeAllAnimations()
        host.mask = nil
    }
}
