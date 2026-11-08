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
    /// A gradient (``GroupGradient``, `sidebar.groupGradient`) stepped down the sidebar: each colored group takes the
    /// gradient's color at its place among them, so neighbors step through it and a group that moves recolors. Leo,
    /// 2026-11-07: "imagine the gradients are just, like, based off of placement, and they're not, like, just static.
    /// They're, like, dynamic."
    case gradient
    /// The desktop picture (Leo, 2026-11-07: "have hints of your background wallpaper, or some other selection of the
    /// background wallpaper as possible for the thing. You know, like a pictorial group"): each colored group takes the
    /// picture's color at the height of its place in the list, softened, top group from the top of the picture.
    case pictorial

    /// Whether a new group takes this palette's next color (``GroupColor/automatic(existing:)``);
    /// under ``glass`` it gets none.
    public var colorsNewGroups: Bool { self != .glass }

    /// Whether the palette follows the desktop picture, so the picture is sampled for it.
    public var followsWallpaper: Bool { self == .wallpaper || self == .pictorial }

    /// The palette a stored color draws from: ``glass`` draws ``vibrant``.
    public var drawn: GroupPalette { self == .glass ? .vibrant : self }
}
