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
    /// The terminal theme as Ghostty config lines (`GhosttyRuntime.phoneTerminalThemeLines`): the
    /// phone's terminals load these, apart from the chrome's colors above (which an app theme can
    /// replace). Empty sends none.
    public var terminal: [String]
    /// The rest of the look the windows show (window style, glass, fonts, chat and group colors); nil
    /// sends none, as an app that predates it.
    public var look: Look?

    public init(background: String, foreground: String, palette: [String], selectionBackground: String? = nil,
                selectionForeground: String? = nil, cursor: String? = nil, accent: String = "neutral",
                accentColor: String? = nil, backgroundOpacity: Double = 1, wallpaper: URL? = nil,
                wallpaperTintOpacity: Double = 0, terminal: [String] = [], look: Look? = nil) {
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
        self.terminal = terminal
        self.look = look
    }
}

extension MobileHostAppearance {
    /// The look beyond the colors, as the app shows it; every field optional (nil sends none).
    /// hostd checks each on its own and drops a bad one (`appearance.rs` `sanitize_look`).
    public struct Look: Sendable, Equatable {
        /// `appearance.chromeStyle` (`ChromeStyle` raw value), `two-tone` included.
        public var chromeStyle: String?
        /// `appearance.hue`, 0...1, as `AppearanceTuning` applies it.
        public var hue: Double?
        /// `appearance.saturation`, 0...2.
        public var saturation: Double?
        /// `appearance.glassTransparency`, 0...1.
        public var glassTransparency: Double?
        /// `appearance.sidebarSurface` (`SidebarSurface` raw value).
        public var sidebarSurface: String?
        /// The family the terminals draw in (`terminal.fontFamily`, else the Ghostty config's).
        public var terminalFontFamily: String?
        /// The terminals' size in points (`terminal.fontSize`, else the Ghostty config's).
        public var terminalFontSize: Double?
        /// `home.bubbleColors.*` as `#rrggbb`, by role: `sent`, `sentText`, `received`, `receivedText`.
        public var chatColors: [String: String]
        /// `sidebar.groupPalette` (`GroupPalette` raw value).
        public var groupPalette: String?
        /// `sidebar.groupGradient` (`GroupGradient` raw value).
        public var groupGradient: String?

        public init(chromeStyle: String? = nil, hue: Double? = nil, saturation: Double? = nil,
                    glassTransparency: Double? = nil, sidebarSurface: String? = nil, terminalFontFamily: String? = nil,
                    terminalFontSize: Double? = nil, chatColors: [String: String] = [:], groupPalette: String? = nil,
                    groupGradient: String? = nil) {
            self.chromeStyle = chromeStyle
            self.hue = hue
            self.saturation = saturation
            self.glassTransparency = glassTransparency
            self.sidebarSurface = sidebarSurface
            self.terminalFontFamily = terminalFontFamily
            self.terminalFontSize = terminalFontSize
            self.chatColors = chatColors
            self.groupPalette = groupPalette
            self.groupGradient = groupGradient
        }

        /// The `look` object of the control line (PROTOCOL.md, `appearance`), only the fields set.
        var json: [String: Any] {
            let roles = ["sent": "sent", "sentText": "sent_text", "received": "received", "receivedText": "received_text"]
            let font = Self.present(["family": terminalFontFamily, "size": terminalFontSize])
            let chat = Self.present(Dictionary(uniqueKeysWithValues: roles.map { ($0.value, chatColors[$0.key]) }))
            let groups = Self.present(["palette": groupPalette, "gradient": groupGradient])
            return Self.present([
                "chrome_style": chromeStyle, "hue": hue, "saturation": saturation, "glass_transparency": glassTransparency,
                "sidebar_surface": sidebarSurface, "terminal_font": font.isEmpty ? nil : font,
                "chat": chat.isEmpty ? nil : chat, "groups": groups.isEmpty ? nil : groups,
            ])
        }

        /// `fields` without the unset ones.
        private static func present(_ fields: [String: Any?]) -> [String: Any] { fields.compactMapValues { $0 } }
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
        if !appearance.terminal.isEmpty { object["terminal"] = appearance.terminal }
        if let look = appearance.look?.json, !look.isEmpty { object["look"] = look }
        if let wallpaper = appearance.wallpaper {
            object["wallpaper"] = ["path": wallpaper.path, "tint_opacity": appearance.wallpaperTintOpacity]
        }
        return anyLine(object)
    }
}
