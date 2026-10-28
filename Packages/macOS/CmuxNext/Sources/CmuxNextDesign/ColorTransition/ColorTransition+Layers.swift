public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// ``ColorTransition`` on layers: a blend of a layer color on the render server, and the
/// transition in effect now. The value (curve, timing, the color mix, the CSS form) is
/// CmuxNextDesignTokens'; the layer half needs QuartzCore and the app's theme store.
nonisolated extension ColorTransition {
    /// The layer animation key of a background color blend.
    public static let layerKey = LayerColor.backgroundColor.animationKey

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

    // MARK: Colors

    package static func rgb(_ color: CGColor?) -> ThemeRGB? {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4 else { return nil }
        return ThemeRGB(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
    }

    package static func cgColor(_ color: ThemeRGB) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
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
