import AppKit
import CmuxNextCompat

/// The agents' glow over a window's backdrop (``BackdropAgentGlow``, `appearance.agentGlow`): one
/// radial gradient, clear in the middle and the machine's color at the edges, over the art, the
/// video, the living wallpaper and the tint, under the window's content.
///
/// It draws only when the glow changes, eased (`scrim`), and then holds: no frame clock, no timer.
/// Calm, it is hidden, so the setting off (the default) or every agent idle adds nothing to draw.
final class BackdropAgentGlowView: NSView {
    private let gradient = CAGradientLayer()
    /// The glow shown, or fading in; ``BackdropAgentGlow/calm`` once a fade-out ends.
    private(set) var shown = BackdropAgentGlow.calm
    /// Bumped by each fade: only the latest fade-out's completion hides the view.
    private var fade = 0
    private var following: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        isHidden = true
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        // Past the corners, so the color rises toward every edge with no ring.
        gradient.endPoint = CGPoint(x: 1.15, y: 1.15)
        gradient.locations = [0.45, 1]
        gradient.opacity = 0
        gradient.frame = bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(gradient)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit { following?.cancel() }

    /// Decoration only: clicks reach the views above or the window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Follows ``DesignSettings/agentGlow`` from now on.
    func follow(_ design: DesignSettings = .shared) {
        show(design.agentGlow, fades: false)
        following?.cancel()
        following = Task { [weak self] in
            for await glow in ObservationStream({ design.agentGlow }) { self?.show(glow) }
        }
    }

    /// Shows `glow`, eased while the window is on screen.
    func show(_ glow: BackdropAgentGlow, fades: Bool = true) {
        guard glow != shown else { return }
        shown = glow
        if let color = glow.color {
            gradient.colors = [color.withAlpha(0).cgColor, color.withAlpha(BackdropAgentGlow.edgeAlpha).cgColor]
        }
        let target = glow.opacity
        guard fades, window?.isVisible == true else {
            fade += 1
            gradient.removeAnimation(forKey: "opacity")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.opacity = target
            CATransaction.commit()
            isHidden = target == 0
            return
        }
        fade += 1
        let current = fade
        let wasHidden = isHidden
        isHidden = false
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self] in
            guard let self, self.fade == current, self.shown.level == .calm else { return }
            self.isHidden = true
        }
        // From what shows now (a reversal mid-fade continues from there), or from 0 when hidden.
        Motion.overlays.set(gradient, "opacity", to: target, fade: .scrim, from: wasHidden ? Float(0) : nil)
        CATransaction.commit()
    }
}
