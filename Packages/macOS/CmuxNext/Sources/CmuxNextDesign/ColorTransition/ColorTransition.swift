public import AppKit
import CCmuxMotionFFI
public import CmuxTheme
public import CmuxNextDesignTokens

/// How every theme and color change animates (`appearance.colorTransition.*`, cx-3rf4z; Lawrence
/// 2026-10-15: "always smooth animation (that can be configured, fully ... or even just instant").
///
/// One value, read by every place a color changes: a layer color blends from the color on screen
/// (``animate(_:to:)``: OKLab or sRGB keyframes on the render server, so a quick A, B, C
/// switch retargets from the blend in flight and never jumps back; a theme repaint blends every
/// layer color its views' hooks change the same way, `ThemeRepaint`), terminal surfaces blend their
/// palette and default colors on the GPU along the same curve (`keyframeProgress`), colors drawn in
/// `draw(_:)` switch at once, and web pages transition their theme variables with the same duration
/// and curve (``cssTransition``). Every curve, the spring's timing and the color mix come from
/// cmux-motion (`CCmuxMotionFFI`: `cmux_motion_ease`, `cmux_motion_cubic_bezier`,
/// `cmux_motion_spring_progress_monotone`, `cmux_motion_mix_rgba`); nothing here keeps its own
/// clock or its own curve math.
public nonisolated struct ColorTransition: Sendable, Hashable {
    /// The timing curve (`appearance.colorTransition.curve`).
    public enum Curve: Sendable, Hashable {
        case easeOut
        case easeInOut
        case linear
        /// A spring; its length is its own settle time, not ``ColorTransition/duration``.
        case spring(SpringParameters)
        /// CSS `cubic-bezier(x1, y1, x2, y2)`; x values are clamped into 0...1.
        case cubicBezier(Double, Double, Double, Double)
    }

    /// What a color change does while macOS Reduce Motion is on.
    public enum ReduceMotion: String, Sendable, Hashable, CaseIterable {
        /// At most ``ColorTransition/reducedMotionCap`` seconds.
        case crossfade
        case instant
        /// Reduce Motion does not change color changes.
        case full
    }

    /// False: every color change applies in one frame.
    public var enabled: Bool
    /// Seconds of a timed curve (0 is instant).
    public var duration: TimeInterval
    public var curve: Curve
    public var space: ThemeColorSpace
    public var reduceMotion: ReduceMotion

    /// The longest color change under Reduce Motion with ``ReduceMotion/crossfade`` (the motion
    /// policy's Reduce Motion fade cap, `MotionFade.crossfade`).
    public static let reducedMotionCap: TimeInterval = 0.1
    /// Keyframes of one layer color blend: enough that the straight segments between OKLab
    /// samples differ from the true path by less than one 8-bit step.
    static let keyframes = 24
    /// The layer animation key of a background color blend.
    public static let layerKey = LayerColor.backgroundColor.animationKey

    public init(enabled: Bool = true, duration: TimeInterval = MotionTunables.colorTransitionDefaultDuration, curve: Curve = .easeOut,
                space: ThemeColorSpace = .oklab, reduceMotion: ReduceMotion = .crossfade) {
        self.enabled = enabled
        self.duration = duration
        self.curve = curve
        self.space = space
        self.reduceMotion = reduceMotion
    }

    // MARK: Resolution

    /// This transition as it runs now: `ui.animationSpeed` off or Reduce Motion applied.
    public func resolved(speedOff: Bool, systemReduceMotion: Bool) -> ColorTransition {
        var resolved = self
        if speedOff || !enabled { resolved.enabled = false }
        if systemReduceMotion {
            switch reduceMotion {
            case .instant: resolved.enabled = false
            case .crossfade:
                // A short timed blend: a spring would outlast the cap.
                resolved.duration = min(seconds, Self.reducedMotionCap)
                if case .spring = curve { resolved.curve = .easeOut }
            case .full: break
            }
        }
        return resolved
    }

    /// Seconds one change takes (a spring: until it first comes within 0.5% of the target, where
    /// a color holds); 0 when instant.
    public var seconds: TimeInterval {
        guard enabled else { return 0 }
        if case .spring(let spring) = curve { return Self.arrival(of: spring) }
        return duration.isFinite ? max(duration, 0) : 0
    }

    /// The first time a spring from rest reaches 99.5% of its way (at most 5 s; cmux-motion).
    static func arrival(of spring: SpringParameters) -> TimeInterval {
        cmux_motion_spring_arrival(CmuxMotionSpring(response: spring.response, damping_fraction: spring.dampingFraction))
    }

    /// The change applies in one frame.
    public var isInstant: Bool { seconds <= 0 }

    /// Progress (0...1, a custom Bezier may leave it) at time fraction `t` of ``seconds``, from
    /// cmux-motion: the named curves (`cmux_motion_ease`), the custom Bezier
    /// (`cmux_motion_cubic_bezier`) and the spring (`cmux_motion_spring_progress_monotone`: it
    /// never decreases, so a color never overshoots or dips back).
    public func progress(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch curve {
        case .easeOut: return cmux_motion_ease(1, t)
        case .easeInOut: return cmux_motion_ease(2, t)
        case .linear: return cmux_motion_ease(3, t)
        case .cubicBezier(let x1, let y1, let x2, let y2): return cmux_motion_cubic_bezier(x1, y1, x2, y2, t)
        case .spring(let spring):
            if t >= 1 { return 1 }
            let parameters = CmuxMotionSpring(response: spring.response, damping_fraction: spring.dampingFraction)
            return cmux_motion_spring_progress_monotone(parameters, t * seconds)
        }
    }

    /// The curve as a layer color blend samples it: `progress(at:)` at ``keyframes`` evenly spaced
    /// time fractions, ending on exactly 1. Terminal surfaces blend their colors on the GPU along
    /// the same samples (`ghostty_surface_set_color_transition`), so text and backgrounds move
    /// together with the window.
    public var keyframeProgress: [Double] { progressSamples(count: Self.keyframes) }

    /// The blend mixes plain sRGB channels (``space`` is sRGB), not OKLab.
    public var mixesInSRGB: Bool { space == .srgb }

    /// `progress(at:)` at `count` evenly spaced time fractions, ending on exactly 1.
    func progressSamples(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { $0 == count - 1 ? 1 : progress(at: Double($0) / Double(count - 1)) }
    }

    /// The color `fraction` of the way from `from` to `to` in ``space`` (cmux-motion
    /// `cmux_motion_mix_rgba`: straight RGBA in and out, mixed premultiplied).
    public func mix(_ from: ThemeRGB, _ to: ThemeRGB, fraction: Double) -> ThemeRGB {
        var out = [0.0, 0.0, 0.0, 0.0]
        let a = [from.red, from.green, from.blue, from.alpha], b = [to.red, to.green, to.blue, to.alpha]
        let mixed = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { po in
                    cmux_motion_mix_rgba(pa.baseAddress, pb.baseAddress, fraction, space == .srgb ? 1 : 0, po.baseAddress)
                }
            }
        }
        guard mixed else { return fraction < 0.5 ? from : to }
        return ThemeRGB(red: out[0], green: out[1], blue: out[2], alpha: out[3])
    }

    // MARK: Layers

    /// Sets `layer`'s background color to `color`, blending from the color on screen (the
    /// presentation value, so a blend in flight continues from where it is) in ``space`` with
    /// ``curve``. Instant: the model value only, and any blend in flight stops.
    @MainActor
    public func animate(_ layer: CALayer, to color: CGColor?) {
        let shown = LayerColor.backgroundColor.shown(in: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()
        blend(layer, .backgroundColor, from: shown, to: color)
    }

    /// Blends `property` of `layer`, whose model value is already `color`, from `shown` (what the
    /// screen showed before the change) on the render server: keyframes at even times, each the
    /// color at the curve's progress there (cmux-motion), so the render server only steps
    /// linearly between them. Instant, a change to or from no color, or no change: any blend of
    /// `property` in flight stops and the model value shows.
    @MainActor
    func blend(_ layer: CALayer, _ property: LayerColor, from shown: CGColor?, to color: CGColor?) {
        let key = property.animationKey
        guard !isInstant, let from = Self.rgb(shown), let to = Self.rgb(color), from != to else {
            layer.removeAnimation(forKey: key)
            return
        }
        let count = Self.keyframes
        var values: [CGColor] = progressSamples(count: count).map { Self.cgColor(mix(from, to, fraction: $0)) }
        // The exact colors at both ends, so removing the animation changes nothing on screen.
        if let shown, let color { values[0] = shown; values[count - 1] = color }
        layer.add(Motion.sampledKeyframes(property.rawValue, values: values, duration: seconds), forKey: key)
    }

    // MARK: Web pages

    /// The CSS `transition-duration` value (`0ms` when instant).
    public var cssDuration: String { "\(Int((seconds * 1000).rounded()))ms" }

    /// The CSS `transition-timing-function` value: the same curve as native, a spring as
    /// `linear()` stops sampled from its closed form.
    public var cssEasing: String {
        switch curve {
        case .easeOut: return "cubic-bezier(0, 0, 0.58, 1)"
        case .easeInOut: return "cubic-bezier(0.42, 0, 0.58, 1)"
        case .linear: return "linear"
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return "cubic-bezier(\(Self.css(min(max(x1, 0), 1))), \(Self.css(y1)), \(Self.css(min(max(x2, 0), 1))), \(Self.css(y2)))"
        case .spring:
            return "linear(" + progressSamples(count: 24).map(Self.css).joined(separator: ", ") + ")"
        }
    }

    // MARK: Colors

    static func rgb(_ color: CGColor?) -> ThemeRGB? {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4 else { return nil }
        return ThemeRGB(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
    }

    static func cgColor(_ color: ThemeRGB) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func css(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

extension ColorTransition {
    /// The transition in effect now: `appearance.colorTransition.*` under the `feedback` motion
    /// category (`ui.animations.feedback`, the master switch, `ui.animationSpeed`) and Reduce Motion.
    /// Instant until the Ghostty config first reached the windows, so a launch shows its first
    /// colors at once. `ui.animationSpeed: normal` does not lengthen it: the duration is the
    /// user's own number.
    @MainActor
    public static var current: ColorTransition {
        guard ThemeScope.app.store.hasAppliedConfig else { return ColorTransition(enabled: false) }
        return DesignSettings.shared.colorTransition.resolved(speedOff: !Motion.feedback.isEnabled, systemReduceMotion: Motion.reduceMotion)
    }
}
