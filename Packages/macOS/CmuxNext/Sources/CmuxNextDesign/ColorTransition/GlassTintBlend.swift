import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

/// The Liquid Glass tint of a window backdrop moving to a new color with the color transition
/// (`appearance.colorTransition`, cx-3rf4z). `NSGlassEffectView.tintColor` is not a layer
/// property Core Animation can interpolate, so the glass takes the new color once and
/// ``overlay`` (a plain layer over the glass) shows the tint that was on screen and fades out on
/// the transition's curve on the render server (I5, cx-8w027.3: no per-frame main-thread step).
/// A change during a blend starts the overlay from the color shown then. Instant transitions and
/// windows not on screen set the tint at once.
@MainActor
final class GlassTintBlend {
    /// Lies over the glass, under every other backdrop layer; hidden while no blend runs.
    let overlay = NSView()
    static let key = "cmux.colorTransition.glassTint"
    private var generation = 0

    init() {
        overlay.wantsLayer = true
        overlay.isHidden = true
        // Its color is what the screen showed, not a theme color for a repaint to blend.
        ThemeRepaint.ownsBlend(overlay.layer)
    }

    /// Moves `glass`'s tint to `color` (nil clears it at once). `view` is the backdrop the glass
    /// lies in.
    func set(_ glass: GlassPanelView, to color: NSColor?, in view: NSView) {
        let previous = glass.tintColor.flatMap(Self.rgb)
        guard let color, let target = Self.rgb(color) else {
            stop()
            glass.tintColor = color
            return
        }
        guard previous != target else { return }
        let transition = ColorTransition.current
        guard let previous, let layer = overlay.layer, !transition.isInstant,
              let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else {
            stop()
            glass.tintColor = color
            return
        }
        // The tint on screen: the overlay of a blend in flight over the glass's old tint.
        let presented = layer.presentation()
        let opacity = layer.animation(forKey: Self.key) != nil ? Double(presented?.opacity ?? 0) : 0
        let shown = ColorTransition.rgb(presented?.backgroundColor ?? layer.backgroundColor)
            .map { transition.mix(previous, $0, fraction: opacity) } ?? previous
        glass.tintColor = color
        generation += 1
        let current = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setMainCompletion { [weak self] in
            guard let self, self.generation == current else { return }
            self.overlay.isHidden = true
        }
        layer.backgroundColor = ColorTransition.cgColor(shown)
        layer.opacity = 0
        overlay.isHidden = false
        let opacities: [Any] = transition.progressSamples(count: ColorTransition.keyframes).map { Float(1 - min(max($0, 0), 1)) }
        layer.add(Motion.sampledKeyframes("opacity", values: opacities, duration: transition.seconds), forKey: Self.key)
        CATransaction.commit()
    }

    private func stop() {
        generation += 1
        overlay.layer?.removeAnimation(forKey: Self.key)
        overlay.isHidden = true
    }

    private static func rgb(_ color: NSColor) -> ThemeRGB? {
        ColorTransition.rgb(color.cgColor)
    }
}
