/// The terminal background-blur mode parsed from the `background-blur` Ghostty
/// config directive and mirrored from libghostty's `Int16` C value.
///
/// The window-chrome bridge (`windowGlassStyle -> WindowGlassEffect.Style`)
/// lives app-side as an extension, since `WindowGlassEffect` is window-domain
/// and must not be a dependency of the terminal core.
public enum GhosttyBackgroundBlur: Equatable, Sendable {
    /// No blur.
    case disabled
    /// A gaussian blur of the given radius in points.
    case radius(Int)
    /// The macOS "regular" glass material.
    case macosGlassRegular
    /// The macOS "clear" glass material.
    case macosGlassClear

    /// Maps libghostty's `Int16` background-blur value: `0` disabled, `-1`
    /// regular glass, `-2` clear glass, positive values a blur radius.
    public init(cValue value: Int16) {
        switch value {
        case 0:
            self = .disabled
        case -1:
            self = .macosGlassRegular
        case -2:
            self = .macosGlassClear
        case 1...:
            self = .radius(Int(value))
        default:
            self = .disabled
        }
    }

    /// Whether this blur mode is one of the macOS glass materials (as opposed to
    /// a gaussian compositor blur or no blur).
    public var isMacOSGlassStyle: Bool {
        switch self {
        case .macosGlassRegular, .macosGlassClear:
            return true
        case .disabled, .radius:
            return false
        }
    }
}
