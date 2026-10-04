public import CmuxTheme

/// Optional per-surface colors. An unset entry always resolves to the
/// theme's single surface background, so customization never creates a
/// second implicit palette.
public struct SurfaceBackgroundOverrides: Equatable, Sendable {
    public var sidebar: ThemeRGB?
    public var tabStrip: ThemeRGB?
    public var terminal: ThemeRGB?
    public var browser: ThemeRGB?
    public var internalPage: ThemeRGB?
    public var agentPane: ThemeRGB?
    public var splitDivider: ThemeRGB?
    public var settings: ThemeRGB?

    public init(sidebar: ThemeRGB? = nil, tabStrip: ThemeRGB? = nil, terminal: ThemeRGB? = nil,
                browser: ThemeRGB? = nil, internalPage: ThemeRGB? = nil, agentPane: ThemeRGB? = nil,
                splitDivider: ThemeRGB? = nil, settings: ThemeRGB? = nil) {
        self.sidebar = sidebar
        self.tabStrip = tabStrip
        self.terminal = terminal
        self.browser = browser
        self.internalPage = internalPage
        self.agentPane = agentPane
        self.splitDivider = splitDivider
        self.settings = settings
    }
}

extension ThemeTokens {
    /// Applies explicit user colors while preserving the theme token as the
    /// default ground for every surface.
    public func applying(_ overrides: SurfaceBackgroundOverrides) -> ThemeTokens {
        var result = self
        let ground = surfaceBackground
        result.windowBackground = overrides.terminal ?? ground
        result.contentBackground = overrides.browser ?? overrides.internalPage ?? overrides.terminal ?? ground
        result.sidebarBackground = overrides.sidebar ?? ground
        result.stripBackground = overrides.tabStrip ?? ground
        result.paneBorder = overrides.splitDivider ?? paneBorder
        return result
    }
}
