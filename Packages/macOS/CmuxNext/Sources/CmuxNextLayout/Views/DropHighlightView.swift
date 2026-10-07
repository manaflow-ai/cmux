import AppKit
import CmuxNextDesign
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
    /// Called when a tunable change needs a redraw while nothing moves.
    var needsFrame: () -> Void = {}

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
        observeTunables()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderer.applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
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
    /// The outline style's renderer, when that style draws (tests, debug).
    var outline: OutlineRenderer? { renderer as? OutlineRenderer }

    // MARK: Showing

    /// Moves the overlay to `rect` inside `region` (superview coordinates).
    /// `pointer` is where the drag is (morph grows from it). Returns true
    /// if an animation frame is needed. Tokens and tunables are re-read on
    /// every call, so a change applies to the next pointer move.
    func show(_ rect: CGRect, region: CGRect, zone: DropOverlayZone, text: String, inset: CGFloat, cornerRadius: CGFloat,
              pointer: CGPoint, animated: Bool) -> Bool {
        refreshStyle()
        let animated = animated && DropOverlayTunables.animated.value
        let target = rect.insetBy(dx: inset, dy: inset)
        self.zone = zone
        self.label = text
        self.cornerRadius = cornerRadius
        refused = false
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
        apply(animated: animated)
        return animated && !renderer.drivesOwnMotion
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
    var labelText: String { label }

    func hide(animated: Bool) -> Bool {
        guard isShowing else { return false }
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
        let token: MotionSpring = renderer.style == .morph ? .settle : DropOverlayTunables.spring.value
        let parameters = Motion.spring(token)
        let alphaParameters = Motion.spring(.track)
        let a = targetSpring.advance(dt, parameters: parameters, alphaParameters: alphaParameters)
        let b = regionSpring.advance(dt, parameters: parameters)
        apply()
        return a || b
    }

    // MARK: Private

    private func apply(animated: Bool = false) {
        if let superview, frame != superview.bounds { frame = superview.bounds }
        renderer.update(DropOverlayFrame(target: targetSpring.rect, finalTarget: targetSpring.targetRect, region: regionSpring.rect,
                                         zone: zone, bounds: bounds,
                                         cornerRadius: cornerRadius, label: label, showsLabel: DropOverlayTunables.showLabel.value,
                                         refused: refused, animated: animated))
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

    /// Redraws on any drop overlay tunable change (style switches live
    /// mid-drag, or while `debug.drop_highlight` holds the overlay still).
    /// One-shot Observation, re-armed after each change; no polling.
    private func observeTunables() {
        withObservationTracking {
            _ = DropOverlayStyle.current
            for descriptor in DropOverlayTunables.all { _ = TunableStore.shared.override(descriptor.key) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStyle()
                if self.isShowing || !self.isHidden {
                    self.renderer.applyTheme()
                    self.apply()
                    self.needsFrame()
                }
                self.observeTunables()
            }
        }
    }
}
