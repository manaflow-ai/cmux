public import CmuxTheme
public import CoreGraphics

/// What a theme adds to the look beyond its colors and window background (Leo, 2026-11-17: "ok i
/// feel like a [character] theme necessarily has to have lots of [character] wallpapers among
/// other flourishes"): the focused pane's accent glow, the tab close button's colors, the sidebar
/// header picture and the art behind each pane (schemas/settings/source/appearance.json, Theme
/// Flourishes). Every part unset is today's look. Values only; `ThemeFlourishSetting` reads them
/// and the views draw them.
public nonisolated struct ThemeFlourishes: Hashable, Sendable {
    /// `appearance.accentGlow.*`: a glow around the focused pane.
    public struct Glow: Hashable, Sendable {
        public var dark: ThemeRGB
        public var light: ThemeRGB
        public var radius: CGFloat
        public var opacity: CGFloat

        public init(dark: ThemeRGB, light: ThemeRGB, radius: CGFloat, opacity: CGFloat) {
            self.dark = dark
            self.light = light
            self.radius = radius
            self.opacity = opacity
        }

        /// The color for the window's appearance.
        public func color(dark isDark: Bool) -> ThemeRGB { isDark ? dark : light }
    }

    /// `appearance.tabClose.*`: the close button's resting color and the color it blends to under
    /// the pointer. A nil end keeps today's color for it.
    public struct TabClose: Hashable, Sendable {
        public var from: ThemeRGB?
        public var toDark: ThemeRGB?
        public var toLight: ThemeRGB?
        public var space: ThemeColorSpace

        public init(from: ThemeRGB? = nil, toDark: ThemeRGB? = nil, toLight: ThemeRGB? = nil, space: ThemeColorSpace = .oklab) {
            self.from = from
            self.toDark = toDark
            self.toLight = toLight
            self.space = space
        }

        /// The hover color for the window's appearance.
        public func to(dark isDark: Bool) -> ThemeRGB? { isDark ? toDark : toLight }
        /// Whether any part differs from today's close button.
        public var isSet: Bool { from != nil || toDark != nil || toLight != nil }
    }

    /// Nil: no glow (the default).
    public var accentGlow: Glow?
    public var tabClose = TabClose()
    /// `appearance.sidebarHeader.*`: one picture, or a light/dark pair. Nil: no header.
    public var sidebarHeader: BackdropSelection?
    /// `appearance.paneArt.*`: the pictures panes take in turn, each one picture or a light/dark
    /// pair. Empty: panes show the window background as `appearance.paneBackgrounds` says.
    public var paneArt: [BackdropSelection] = []

    public init() {}

    /// Today's look.
    public static let none = ThemeFlourishes()

    /// The picture of the pane at `index` (its place among the window's panes), or nil when the
    /// theme carries no pane art. Panes take the list in turn, so a window shows each picture
    /// before it repeats one.
    public func paneArt(at index: Int) -> BackdropSelection? {
        guard !paneArt.isEmpty else { return nil }
        return paneArt[((index % paneArt.count) + paneArt.count) % paneArt.count]
    }
}
