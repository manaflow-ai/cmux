/// Where sidebar group colors come from, and the source of a new group's color
/// (`sidebar.groupPalette`). Leo, 2026-11-06: "if it's a choice between frumpy colors or no
/// colors at all slash black and white, you just pick black and white"; "you can have just... No
/// color group, you know, just pure glass. And then alternatively you can have, like, you know,
/// the grayscale thing"; "one of them is obviously your app theme. The second one is from your
/// desktop wallpaper. The third is perhaps, like, grayscale ... just, like, vibrant nice colors".
///
/// Every palette draws the same eight color tokens (`GroupColor`) its own way, so a group's
/// stored color never changes when the palette does: it is drawn from the new palette.
public nonisolated enum GroupPalette: String, Hashable, Sendable, CaseIterable {
    /// Pure glass: a new group gets no color. A group a person colored draws its color from
    /// ``vibrant``. The default.
    case glass
    /// The app theme's terminal colors (its ANSI palette).
    case theme
    /// Colors around the desktop picture's hue.
    case wallpaper
    /// Eight greys, each a little warm or cool so neighbors stay apart.
    case grayscale
    /// cmux's own colors, bright enough to read as color on dark and light glass.
    case vibrant

    /// Whether a new group takes this palette's next color (``GroupColor/automatic(existing:)``);
    /// under ``glass`` it gets none.
    public var colorsNewGroups: Bool { self != .glass }

    /// The palette a stored color draws from: ``glass`` draws ``vibrant``.
    public var drawn: GroupPalette { self == .glass ? .vibrant : self }
}
