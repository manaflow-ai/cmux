import CmuxNextDesign
import CoreGraphics

/// The SDK motion props of a node (`cmux-app-host/js/ABI.md` "Motion"), parsed from its scene props.
/// A value the renderer does not know parses to nil or the identity: no motion, never a crash.
extension AppSceneNode {
    /// `animation`: a token name, `{ spring: { response, dampingFraction } }` or `{ duration, curve? }`.
    var motion: SceneMotion? { Self.sceneMotion(props["animation"]) }

    /// A motion value (`animation`, or a timed `transition`'s `motion`); nil when it is not one.
    static func sceneMotion(_ value: AppJSON?) -> SceneMotion? {
        switch value {
        case .string(let name)?: return SceneMotion.named(name)
        case .object(let fields)?:
            if let spring = fields["spring"]?.objectValue {
                guard let response = spring["response"]?.numberValue, let damping = spring["dampingFraction"]?.numberValue else { return nil }
                return SceneMotion.custom(response: response, dampingFraction: damping)
            }
            if let seconds = fields["duration"]?.numberValue {
                return SceneMotion.timed(seconds: seconds, curve: fields["curve"]?.stringValue)
            }
            return nil
        default: return nil
        }
    }

    /// `loop`: `{ effect, period?, amount? }`.
    var loop: SceneLoop? {
        guard let fields = props["loop"]?.objectValue, let effect = fields["effect"]?.stringValue else { return nil }
        return SceneLoop(effect: effect, period: fields["period"]?.numberValue, amount: fields["amount"]?.numberValue)
    }

    /// `transition`: `opacity`, `slide`, `scale`, `move` or `pop`, bare or as `{ kind, motion? }`.
    var transition: SceneTransition? {
        let kind = props["transition"]?.stringValue ?? props["transition"]?.objectValue?["kind"]?.stringValue
        return kind.flatMap(SceneTransition.init(rawValue:))
    }

    /// A timed transition's `motion` (`{ kind, motion }`); nil keeps the transition's own springs.
    var transitionMotion: SceneMotion? { Self.sceneMotion(props["transition"]?.objectValue?["motion"]) }

    /// `scale`: 1 is the identity; clamped to [0, 100].
    var scaleFactor: CGFloat { CGFloat(Self.finite(number("scale"), in: 0...100) ?? 1) }

    /// `rotation`: degrees clockwise.
    var rotationDegrees: CGFloat { CGFloat(Self.finite(number("rotation"), in: -36_000...36_000) ?? 0) }

    /// `offset`: `{ x?, y? }` points, +y down; it does not move the node's layout.
    var offset: CGPoint {
        guard let fields = props["offset"]?.objectValue else { return .zero }
        let range: ClosedRange<Double> = -10_000...10_000
        return CGPoint(x: Self.finite(fields["x"]?.numberValue, in: range) ?? 0, y: Self.finite(fields["y"]?.numberValue, in: range) ?? 0)
    }

    /// `blur`: a Gaussian blur radius in points, clamped to [0, 100].
    var blurRadius: CGFloat { CGFloat(Self.finite(number("blur"), in: 0...100) ?? 0) }

    /// `clipped`: the node clips its content (children, their transitions and glows) to its frame
    /// and `cornerRadius`; its own glow stays outside. Off by default.
    var clipped: Bool { props["clipped"]?.boolValue == true }

    /// `glow`: `{ color, radius, opacity? }`, a colored zero-offset shadow around the node's shape.
    var glow: SceneGlow? {
        guard let fields = props["glow"]?.objectValue, let color = fields["color"], color.stringValue != nil else { return nil }
        return SceneGlow(color: color, radius: CGFloat(Self.finite(fields["radius"]?.numberValue, in: 0...200) ?? 8),
                         opacity: Float(Self.finite(fields["opacity"]?.numberValue, in: 0...1) ?? 1))
    }

    /// `gradient`: `{ colors, angle? }`, a linear fill (shapes) or background (other nodes); degrees,
    /// 0 left to right, 90 (the default) top to bottom. Fewer than two colors is no gradient.
    var gradient: SceneGradient? {
        guard let fields = props["gradient"]?.objectValue, let colors = fields["colors"]?.arrayValue else { return nil }
        let tones = colors.filter { $0.stringValue != nil }
        guard tones.count >= 2 else { return nil }
        return SceneGradient(colors: Array(tones.prefix(16)), angle: CGFloat(Self.finite(fields["angle"]?.numberValue, in: -3600...3600) ?? 90))
    }

    /// `trim`: `{ from?, to }` fractions of a stroked shape's outline (a circle's from 12 o'clock,
    /// clockwise); nil draws the whole outline.
    var trim: (from: CGFloat, to: CGFloat)? {
        guard let fields = props["trim"]?.objectValue, let to = Self.finite(fields["to"]?.numberValue, in: 0...1) else { return nil }
        let from = Self.finite(fields["from"]?.numberValue, in: 0...1) ?? 0
        return (CGFloat(min(from, to)), CGFloat(to))
    }

    static func finite(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A node's `glow`. `color` is the scene color value (a tone or `#RRGGBB[AA]`), resolved in the theme.
nonisolated struct SceneGlow: Hashable {
    var color: AppJSON
    var radius: CGFloat
    var opacity: Float
}

/// A node's `gradient`. `colors` are scene color values, resolved in the theme.
nonisolated struct SceneGradient: Hashable {
    var colors: [AppJSON]
    var angle: CGFloat

    /// The gradient's start and end in a layer's unit square, for `yDown` (whether the layer's
    /// content space has +y down on screen).
    func endpoints(yDown: Bool) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        // Screen direction (+y down), then into the layer's space.
        let dx = cos(radians) / 2, dy = sin(radians) / 2 * (yDown ? 1 : -1)
        return (CGPoint(x: 0.5 - dx, y: 0.5 - dy), CGPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}
