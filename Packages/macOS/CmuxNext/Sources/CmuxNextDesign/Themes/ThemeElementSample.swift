public import CmuxNextDesignTokens

/// One UI element's ink on one ground it is drawn on, in one theme (``ThemeElementAudit``).
///
/// It passes when the ink holds its WCAG 2 minimum on the ground (4.5:1 for text, 3:1 for marks
/// such as dots and glyphs) and the element takes its color from the theme, not from the system's
/// light or dark appearance (``followsSystemAppearance``).
public struct ThemeElementSample: Hashable, Sendable {
    /// The element.
    public let element: ThemeElement
    /// What the element sits on.
    public let ground: ThemeElementGround
    /// The element's color, opaque, composited over ``surface``.
    public let ink: ThemeRGB
    /// The ground, opaque.
    public let surface: ThemeRGB
    /// The WCAG 2 minimum: ``ThemeTokens/minimumTextContrast`` or ``ThemeTokens/minimumMarkContrast``.
    public let minimum: Double
    /// True when the ink or the ground changes with the system's light or dark appearance instead
    /// of the theme (a system color such as `labelColor` or `systemOrange`): unthemed.
    public let followsSystemAppearance: Bool

    /// Creates a sample.
    /// - Parameters:
    ///   - element: The element.
    ///   - ground: What it is drawn on.
    ///   - ink: The element's color, composited over `surface`.
    ///   - surface: The opaque ground.
    ///   - minimum: The WCAG 2 minimum.
    ///   - followsSystemAppearance: Whether the colors follow the system appearance.
    public init(element: ThemeElement, ground: ThemeElementGround, ink: ThemeRGB, surface: ThemeRGB, minimum: Double,
                followsSystemAppearance: Bool) {
        self.element = element
        self.ground = ground
        self.ink = ink
        self.surface = surface
        self.minimum = minimum
        self.followsSystemAppearance = followsSystemAppearance
    }

    /// The WCAG 2 contrast ratio of ``ink`` on ``surface``.
    public var contrast: Double { ink.contrast(with: surface) }

    /// Whether the element reads (``contrast`` at least ``minimum``) and is themed.
    public var passes: Bool { contrast >= minimum && !followsSystemAppearance }
}
