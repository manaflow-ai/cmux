public import AppKit
public import CmuxTheme

/// How every theme and color change animates (`appearance.colorTransition.*`, cx-3rf4z; Lawrence
/// 2026-10-15: "always smooth animation (that can be configured, fully ... or even just instant").
///
/// One value, read by every place a color changes: a layer color blends from the color on screen
/// (``animate(_:to:)``: OKLab or sRGB keyframes on the render server, so a quick A, B, C
/// switch retargets from the blend in flight and never jumps back), a view subtree whose colors
/// cannot be interpolated one by one (terminal surfaces, chrome drawn in `draw(_:)`) crossfades
/// (``crossfade(_:)``), and web pages transition their theme variables with the same duration
/// and curve (``cssTransition``). The curves are Core Animation's (`CAMediaTimingFunction`) and
/// the spring is the motion springs' closed form (`SpringValue.solve`); nothing here keeps its
/// own clock.
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
    static let keyframes = 16
    /// The layer animation key of a background color blend.
    public static let layerKey = "cmux.colorTransition.backgroundColor"

    public init(enabled: Bool = true, duration: TimeInterval = 0.2, curve: Curve = .easeOut,
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

    /// The first time a spring from rest reaches 99.5% of its way (at most 5 s).
    static func arrival(of spring: SpringParameters) -> TimeInterval {
        let step = 1.0 / 240
        var time = 0.0
        while time < 5 {
            time += step
            if 1 + SpringValue.solve(displacement: -1, velocity: 0, time: time, parameters: spring).displacement >= 0.995 { return time }
        }
        return 5
    }

    /// The change applies in one frame.
    public var isInstant: Bool { seconds <= 0 }

    /// Core Animation's curve for a timed blend (a spring maps time to progress through its
    /// keyframes instead, so it uses linear here).
    public var timingFunction: CAMediaTimingFunction {
        switch curve {
        case .easeOut: CAMediaTimingFunction(name: .easeOut)
        case .easeInOut: CAMediaTimingFunction(name: .easeInEaseOut)
        case .linear, .spring: CAMediaTimingFunction(name: .linear)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            CAMediaTimingFunction(controlPoints: Float(min(max(x1, 0), 1)), Float(y1), Float(min(max(x2, 0), 1)), Float(y2))
        }
    }

    /// Progress (0...1) at each of `count` evenly spaced key times for the spring curve, from
    /// rest (no velocity) toward 1; it never decreases (a color never overshoots or dips back).
    func springProgress(count: Int) -> [Double]? {
        guard case .spring(let spring) = curve, count > 1 else { return nil }
        let total = seconds
        var reached = 0.0
        return (0..<count).map { index in
            if index == count - 1 { return 1 }
            let time = total * Double(index) / Double(count - 1)
            let state = SpringValue.solve(displacement: -1, velocity: 0, time: time, parameters: spring)
            // A color never goes back: past its first arrival it holds (no dip after an overshoot).
            reached = max(reached, min(max(1 + state.displacement, 0), 1))
            return reached
        }
    }

    // MARK: Layers

    /// Sets `layer`'s background color to `color`, blending from the color on screen (the
    /// presentation value, so a blend in flight continues from where it is) in ``space`` with
    /// ``curve``. Instant: the model value only, and any blend in flight stops.
    @MainActor
    public func animate(_ layer: CALayer, to color: CGColor?) {
        let key = Self.layerKey
        let shown = (layer.animation(forKey: key) != nil ? layer.presentation()?.backgroundColor : nil) ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()
        guard !isInstant, let from = Self.rgb(shown), let to = Self.rgb(color), from != to else {
            layer.removeAnimation(forKey: key)
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        let count = Self.keyframes
        let progress = springProgress(count: count)
        var values: [CGColor] = (0..<count).map { index in
            let fraction = progress?[index] ?? Double(index) / Double(count - 1)
            return Self.cgColor(from.mixed(with: to, fraction: fraction, in: space))
        }
        // The exact colors at both ends, so removing the animation changes nothing on screen.
        if let shown, let color { values[0] = shown; values[count - 1] = color }
        animation.values = values
        animation.keyTimes = (0..<count).map { NSNumber(value: Double($0) / Double(count - 1)) }
        animation.calculationMode = .linear
        animation.duration = seconds
        animation.timingFunction = timingFunction
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: key)
    }

    /// Crossfades everything `layer` draws from its last frame to its next one (a theme switch
    /// recoloring in place: no layout change, no restart). For what has no single color to
    /// blend: terminal surfaces, views that draw their own colors. Instant: nothing.
    @MainActor
    public func crossfade(_ layer: CALayer?) {
        guard let layer, !isInstant else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = seconds
        // A crossfade has one timing curve: a spring takes its own settle time on ease-out.
        if case .spring = curve { transition.timingFunction = CAMediaTimingFunction(name: .easeOut) } else {
            transition.timingFunction = timingFunction
        }
        layer.add(transition, forKey: "cmux.themeCrossfade")
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
            let stops = springProgress(count: 24) ?? [0, 1]
            return "linear(" + stops.map(Self.css).joined(separator: ", ") + ")"
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
    /// The transition in effect now: `appearance.colorTransition.*` under `ui.animationSpeed` and
    /// Reduce Motion.
    /// Instant until the Ghostty config first reached the windows, so a launch shows its first
    /// colors at once. `ui.animationSpeed: normal` does not lengthen it: the duration is the
    /// user's own number.
    @MainActor
    public static var current: ColorTransition {
        guard ThemeStore.shared.hasAppliedConfig else { return ColorTransition(enabled: false) }
        return DesignSettings.shared.colorTransition.resolved(speedOff: Motion.speed == .off, systemReduceMotion: Motion.reduceMotion)
    }
}
