import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Observation

/// Shows where a dragged tab will land. The drawing is one of the
/// `DropOverlayStyle`s (Debug Settings `drop.overlay.style`; default the
/// border-only outline, which animates itself on the compositor), switched
/// live even mid-drag. This view
/// covers the overlay plane and owns the motion: the target and its region
/// follow springs (Motion token from the tunable, `settle` for morph), so
/// every style moves the same way; Reduce Motion snaps (the layout passes
/// `animated: false`). Glass styles draw through `OverlaySurfaceView`, so
/// `OverlayMaterial.select` stays the one material choice.
///
/// A style that moves its own layers (`drivesOwnMotion`, the default outline) shows each move when the
/// change turn ends (``commitOwnMove(onRenderServer:)``): with `motion.renderServer` on, the render
/// server takes it as one additive `RenderSpring` retarget per drag event (``DropHighlightRenderMotion``),
/// and the main thread steps no frame for it, as Chromium retargets a compositor animation on input
/// (`cc/animation/scroll_offset_animation_curve.cc`, `UpdateTarget`). A style that redraws its paths from
/// the rect (the Debug Settings experiments) still steps on the CPU while it moves.
final class DropHighlightView: NSView {
    private var renderer: any DropOverlayRenderer
    private var targetSpring = AnimatedFrame(.zero, alpha: 0)
    private var regionSpring = AnimatedFrame(.zero)
    private var zone: DropOverlayZone = .center
    private var label = ""
    private var cornerRadius: CGFloat = 0
    /// The drop is refused (`label` is the reason) or keeps the tabs in
    /// place (`label` says so); set after `show` by the drag (tab-dnd).
    private var refused = false
    private var materialOverride: OverlayMaterial?
    private(set) var isShowing = false
    /// A self-driven style's move ``show`` started; its renderer shows it at the end of the change
    /// turn (``commitOwnMove(onRenderServer:)``).
    private var ownMovePending = false
    /// Moves the render server took, one per drag event that changed the target (tests).
    private(set) var renderServerMoves = 0
    /// Display frames that stepped the highlight's CPU springs (tests).
    private(set) var steps = 0
    /// Called when a tunable change needs a redraw while nothing moves.
    var needsFrame: () -> Void = {}
    /// Follows the drop overlay tunables (``follow(on:)``); nil until the layout root passes its scheduler.
    private var tunablesWatch: FrameObservation<DropTunables>?

    /// Every drop overlay tunable: the style and each override.
    private struct DropTunables: Equatable {
        var style: DropOverlayStyle
        var overrides: [TunableValue?]

        init() {
            style = DropOverlayStyle.current
            overrides = DropOverlayTunables.all.map { TunableStore.shared.override($0.key) }
        }
    }

    /// `material` pins one material (tests); nil follows this Mac.
    init(material: OverlayMaterial? = nil) {
        materialOverride = material
        renderer = DropOverlayRenderers.make(DropOverlayStyle.current, material: material)
        super.init(frame: .zero)
        wantsLayer = true
        install(renderer)
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderer.applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() { // visibility-walk-allow: the outline's layer colors and its label's text color, no layout or text measure; cheaper than a deferral
        super.viewDidChangeEffectiveAppearance()
        renderer.applyTheme()
    }

    // MARK: State for debug and tests

    var style: DropOverlayStyle { renderer.style }
    /// The material glass styles draw in (this Mac's when the style has no glass).
    var material: OverlayMaterial { renderer.material ?? materialOverride ?? OverlayMaterial.current }
    func pinMaterial(_ material: OverlayMaterial?) {
        materialOverride = material
        renderer.pinMaterial(material)
    }
    /// The target rect as drawn now (this view's coordinates).
    var targetRect: CGRect { targetSpring.rect }
    /// The rect the target settles on (this view's coordinates), before any motion reaches it.
    var destinationRect: CGRect { targetSpring.targetRect }
    /// The shown target takes the classic fill (`DropOverlayFrame.fills`).
    private var fills = true
    /// The final frames of the panes the drop resizes (`DropOverlayFrame.companions`).
    private var companions: [CGRect] = []
    /// The outline style's renderer, when that style draws (tests, debug).
    var outline: OutlineRenderer? { renderer as? OutlineRenderer }

    // MARK: Showing

    /// Moves the overlay to `rect` inside `region` (superview coordinates).
    /// `pointer` is where the drag is (morph grows from it). Returns true
    /// if an animation frame is needed. Tokens and tunables are re-read on
    /// every call, so a change applies to the next pointer move.
    func show(_ rect: CGRect, region: CGRect, zone: DropOverlayZone, text: String, inset: CGFloat, cornerRadius: CGFloat,
              pointer: CGPoint, animated: Bool, fills: Bool = true, companions: [CGRect] = []) -> Bool {
        refreshStyle()
        self.fills = fills
        self.companions = companions
        let animated = animated && DropOverlayTunables.animated.value
        let target = rect.insetBy(dx: inset, dy: inset)
        self.zone = zone
        self.label = text
        self.cornerRadius = cornerRadius
        refused = false
        let moves = !isShowing || target != targetSpring.targetRect || region != regionSpring.targetRect
        if !isShowing {
            isShowing = true
            isHidden = false
            let start: CGRect
            if renderer.style == .morph {
                start = DropOverlayGeometry.morphStart(pointer: pointer, width: CGFloat(DropOverlayTunables.morphStartWidth.value))
            } else {
                let share = CGFloat(DropOverlayTunables.appearInset.value)
                start = target.insetBy(dx: target.width * share, dy: target.height * share)
            }
            targetSpring = AnimatedFrame(start, alpha: animated ? 0 : 1)
            regionSpring = AnimatedFrame(region == target ? start : region)
            // Theme changes and tunable changes re-apply colors on their own;
            // a new drag re-reads them once.
            renderer.applyTheme()
        }
        targetSpring.setTarget(target, alpha: 1)
        regionSpring.setTarget(region)
        // A self-driven style animates on the compositor: no frame clock.
        if !animated || renderer.drivesOwnMotion {
            targetSpring.snap()
            regionSpring.snap()
        }
        if animated, moves, renderer.drivesOwnMotion {
            ownMovePending = true
            return false
        }
        apply(animated: animated)
        return animated && !renderer.drivesOwnMotion
    }

    /// Shows the move ``show`` left to a self-driven renderer, once, at the end of its change turn:
    /// as additive `RenderSpring` retargets when `onRenderServer` (``DropHighlightRenderMotion``), else
    /// as the renderer's own Core Animation springs. Returns whether a move was waiting.
    @discardableResult
    func commitOwnMove(onRenderServer: Bool) -> Bool {
        guard ownMovePending else { return false }
        ownMovePending = false
        if onRenderServer { renderServerMoves &+= 1 }
        apply(animated: true, onRenderServer: onRenderServer)
        return true
    }

    /// Replaces the label of the target on show: the reason a drop there
    /// is refused, or that it keeps the tabs in place. Nil restores nothing
    /// (the next `show` sets the target's own label).
    func setNote(_ text: String?, refused: Bool) {
        guard isShowing, let text else { return }
        guard text != label || refused != self.refused else { return }
        label = text
        self.refused = refused
        apply()
    }

    var isRefused: Bool { refused }
    /// A spring of the highlight has not reached its target (``step(_:)`` still moves it).
    var isMoving: Bool {
        [targetSpring, regionSpring].contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
    }
    var labelText: String { label }

    func hide(animated: Bool) -> Bool {
        guard isShowing else { return false }
        ownMovePending = false
        if renderer.drivesOwnMotion {
            isShowing = false
            refused = false
            renderer.hide(animated: animated && DropOverlayTunables.animated.value)
            return false
        }
        isShowing = false
        targetSpring.alpha.target = 0
        if !animated || !DropOverlayTunables.animated.value {
            targetSpring.snap()
            regionSpring.snap()
            apply()
            return false
        }
        return true
    }

    func step(_ dt: Double) -> Bool {
        steps &+= 1
        let token: MotionSpring = renderer.style == .morph ? .settle : DropOverlayTunables.spring.value
        let parameters = Motion.panes.spring(token)
        let alphaParameters = Motion.panes.spring(.track)
        let a = targetSpring.advance(dt, parameters: parameters, alphaParameters: alphaParameters)
        let b = regionSpring.advance(dt, parameters: parameters)
        apply()
        return a || b
    }

    // MARK: Private

    private func apply(animated: Bool = false, onRenderServer: Bool = false) {
        if let superview, frame != superview.bounds { frame = superview.bounds }
        // A self-driven style (the outline ring) fades itself out on hide.
        // Updating it after that would show its last target again: the
        // layout's frames after a drop (the new split animating) brought
        // the ring back, and it stayed (cx-ohle, cx-x7pl).
        if isShowing || !renderer.drivesOwnMotion {
            renderer.update(DropOverlayFrame(target: targetSpring.rect, finalTarget: targetSpring.targetRect, region: regionSpring.rect,
                                             zone: zone, bounds: bounds,
                                             cornerRadius: cornerRadius, label: label, showsLabel: DropOverlayTunables.showLabel.value,
                                             refused: refused, animated: animated, fills: fills,
                                             companions: isShowing ? companions : [], springsOnRenderServer: onRenderServer))
        }
        alphaValue = targetSpring.alpha.value * CGFloat(DropOverlayTunables.opacity.value)
        if !isShowing && targetSpring.alpha.value <= 0.001 { isHidden = true }
    }

    private func install(_ renderer: any DropOverlayRenderer) {
        renderer.view.frame = bounds
        renderer.view.autoresizingMask = [.width, .height]
        addSubview(renderer.view)
        renderer.applyTheme()
    }

    /// Swaps the renderer when the style tunable changed.
    private func refreshStyle() {
        let style = DropOverlayStyle.current
        guard style != renderer.style else { return }
        renderer.view.removeFromSuperview()
        renderer = DropOverlayRenderers.make(style, material: materialOverride)
        install(renderer)
    }

    /// Redraws on any drop overlay tunable change (style switches live mid-drag, or while
    /// `debug.drop_highlight` holds the overlay still), once per frame however many changed; no
    /// polling. A highlight never given a scheduler (tests) reads the tunables at each ``show``.
    func follow(on work: MainWorkScheduler) {
        guard tunablesWatch == nil else { return }
        // node-free: the layout root has no VisibilityNode; a hidden highlight's apply only swaps its renderer.
        tunablesWatch = FrameObservation(owner: "Layout.dropHighlight", delivery: .visible(nil), on: work) {
            DropTunables()
        } onChange: { [weak self] _ in
            self?.tunablesChanged()
        }
    }

    private func tunablesChanged() {
        refreshStyle()
        guard isShowing || !isHidden else { return }
        renderer.applyTheme()
        apply()
        needsFrame()
    }
}
