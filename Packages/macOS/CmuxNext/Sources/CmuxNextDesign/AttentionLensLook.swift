public import CmuxNextDesignTokens
public import CoreGraphics

/// The pane attention ring's glass (Debug Settings `notifications.attention.lens`, the ring's
/// gallery). Leo, 2026-11-02: "I feel like this is a bit too, like, it's a bit too solid. It's
/// just kind of lame.I want, like glassier stuff. I want it to be like a fucking glass, like a
/// lens thing, like a fisheye. I want more fisheye!"
///
/// Every look keeps the ring's color (the theme accent or the user's), width, timing, blink,
/// dismiss flash and per-pane-kind setting: it sets only how the stroke is drawn. The lens draws
/// as sublayers of the ring, so the ring's own opacity animations carry it; it adds no timer,
/// observer or animation loop. Reduce Transparency draws `solid`.
public nonisolated enum AttentionLensLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default: a deep glass lens. Light bends inward off the rim (a soft accent band that
    /// fades into the pane), a caustic line where the lens focuses it, and a specular rim that
    /// catches the light up-left and, fainter, down-right. The stroke itself is translucent.
    case fisheye
    /// A thin lens: the same rim and band at half the depth, no caustic.
    case lens
    /// The fisheye with a chromatic fringe: the caustic splits into a warm and a cool line.
    case prism
    /// The flat stroke before the lens (cmux#23968).
    case solid

    public var tunableTitle: String {
        switch self {
        case .fisheye: "Fisheye (deep glass lens)"
        case .lens: "Lens (thin glass)"
        case .prism: "Prism (fisheye with a chromatic fringe)"
        case .solid: "Solid (the flat stroke)"
        }
    }

    /// The look drawn now: `solid` under Reduce Transparency.
    public func effective(reduceTransparency: Bool) -> AttentionLensLook {
        reduceTransparency ? .solid : self
    }

    /// How deep the lens bends light into the pane, in points: the inward band's width.
    public var depth: CGFloat {
        switch self {
        case .fisheye, .prism: 18
        case .lens: 9
        case .solid: 0
        }
    }

    /// The inward band's strength at the rim (it fades to nothing at `depth`).
    public var bandOpacity: Float {
        switch self {
        case .fisheye, .prism: 0.55
        case .lens: 0.4
        case .solid: 0
        }
    }

    /// The stroke's own alpha: glass is translucent, the solid ring is not.
    public var strokeAlpha: CGFloat {
        switch self {
        case .fisheye, .prism: 0.62
        case .lens: 0.72
        case .solid: 1
        }
    }

    /// The specular rim's peak alpha (the edge facing up-left); the opposite edge gets a third.
    public var specularAlpha: CGFloat {
        switch self {
        case .fisheye, .prism: 0.9
        case .lens: 0.75
        case .solid: 0
        }
    }

    /// Whether the lens draws a caustic line where it focuses the light.
    public var drawsCaustic: Bool { self == .fisheye || self == .prism }

    /// Whether the caustic splits into a warm and a cool line.
    public var splitsCaustic: Bool { self == .prism }

    /// Whether anything but the stroke draws.
    public var isGlass: Bool { self != .solid }

    public static let tunable = Tunable<AttentionLensLook>.choice(
        "notifications.attention.lens", .status, "Attention ring glass",
        help: "How the pane attention ring is drawn: fisheye (default, a deep glass lens with a specular rim), lens (thin glass), prism (fisheye with a chromatic fringe) or solid (the flat stroke). Reduce Transparency draws solid.",
        default: .fisheye, code: "AttentionLensLook.tunable")
}
