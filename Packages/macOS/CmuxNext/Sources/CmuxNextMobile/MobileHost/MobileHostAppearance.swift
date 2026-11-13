public import Foundation

/// What this Mac's chrome looks like, for the iPhone (ask-87d30da8e5): the colors the chrome
/// derives from (`ThemeInput`, as `#rrggbb`) and the picture its windows show. hostd keeps every
/// rule (what is valid, the wallpaper's size and kind, its content id: `cmux-mobile-host`
/// `appearance.rs`); this is only what the app shows.
public struct MobileHostAppearance: Sendable, Equatable {
    public var background: String
    public var foreground: String
    /// ANSI 0...15.
    public var palette: [String]
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var cursor: String?
    /// `appearance.accent` (`ThemeAccent` raw value).
    public var accent: String
    /// The theme's own accent, or the art's hue under Art Color.
    public var accentColor: String?
    public var backgroundOpacity: Double
    /// A phone-sized JPEG of the picture the windows show, nil with none.
    public var wallpaper: URL?
    /// The tint the windows lay over that picture, 0...1.
    public var wallpaperTintOpacity: Double

    public init(background: String, foreground: String, palette: [String], selectionBackground: String? = nil,
                selectionForeground: String? = nil, cursor: String? = nil, accent: String = "neutral",
                accentColor: String? = nil, backgroundOpacity: Double = 1, wallpaper: URL? = nil,
                wallpaperTintOpacity: Double = 0) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.cursor = cursor
        self.accent = accent
        self.accentColor = accentColor
        self.backgroundOpacity = backgroundOpacity
        self.wallpaper = wallpaper
        self.wallpaperTintOpacity = wallpaperTintOpacity
    }
}

extension MobileHostLaunch {
    /// The control line with this Mac's whole appearance (`appearance`).
    public static func appearanceLine(_ appearance: MobileHostAppearance) -> Data {
        var theme: [String: Any] = [
            "background": appearance.background, "foreground": appearance.foreground, "palette": appearance.palette,
            "accent": appearance.accent, "background_opacity": appearance.backgroundOpacity,
        ]
        if let value = appearance.selectionBackground { theme["selection_background"] = value }
        if let value = appearance.selectionForeground { theme["selection_foreground"] = value }
        if let value = appearance.cursor { theme["cursor"] = value }
        if let value = appearance.accentColor { theme["accent_color"] = value }
        var object: [String: Any] = ["type": "appearance", "theme": theme]
        if let wallpaper = appearance.wallpaper {
            object["wallpaper"] = ["path": wallpaper.path, "tint_opacity": appearance.wallpaperTintOpacity]
        }
        return anyLine(object)
    }
}
