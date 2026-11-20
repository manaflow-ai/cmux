public import CoreGraphics

public extension Typography {
    /// The size scale a page's density-following chrome draws at (`--cmux-density-scale`: the composer,
    /// New Tab, the model menu): the density's chrome row (``Metrics/densityRowHeight``: a tab, the omnibar and a
    /// sidebar row) over Default's, so those controls grow and shrink with the tabs (Lucas 2026-11-13: the composer
    /// should change size proportionally with the 20, 30 and 34 pt rows). Unlike ``pageScale`` it goes below 1, so
    /// Compact and Ultra-compact draw them smaller (Lawrence 2026-11-11: "if I change densities, this should change
    /// the size of everything on this page").
    static var pageDensityScale: CGFloat { Metrics.tokens.uniformScale.map { Metrics.scale($0) } ?? (Metrics.densityRowHeight / Metrics.defaultDensityRowHeight) }
    /// The sidebar row's title size over Default's (`--cmux-row-text-scale`): a page's rows (New Tab's suggestions)
    /// draw their text this much larger or smaller than at Default, so they match the density's sidebar rows and tabs
    /// as Default's do (Lucas 2026-11-15: "they need to match the rest of the density").
    /// It carries the person's text scale (``userScale``), as the sidebar's own titles do, so Text Size grows the rows too.
    static var pageRowTextScale: CGFloat {
        sidebarTitleSize(Metrics.tokens) / max(1, sidebarTitleSize(DensityPreset.cozy.tokens)) * userScale
    }
    /// The density's icon box over Default's (`--cmux-row-icon-scale`): a page's row glyphs grow with the sidebar's
    /// and the tabs' icons.
    static var pageRowIconScale: CGFloat {
        Metrics.tabIconSize / max(1, CGFloat(DensityPreset.cozy.tokens.tokens["tabIconSize"] ?? 16))
    }
    /// The text scale beside ``pageDensityScale`` (`--cmux-density-text-scale`): the chrome body size
    /// (Text Size, else the density's) over Default's 13 pt, in both directions.
    static var pageDensityTextScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? Metrics.tokens.bodySize
        return body / DensityPreset.cozy.tokens.bodySize * interfaceScale
    }
    /// The text scale the chats draw at (`--cmux-chat-text-scale`): the agent chat's messages, tool rows,
    /// bubbles and composer. At and below Default it is Default's, so Compact and Ultra-compact draw the chats as
    /// Default does (user 2026-11-16: "make it so compact and default density have same size of both imessage and
    /// chat trajectory"); above it the chats grow with the density as before (``pageDensityTextScale``). Text Size and a chrome font size
    /// set in Settings still apply, as they do at Default.
    static var pageChatTextScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let drawn = DensityPreset.cozy.tokens.bodySize
        // A density's own chat text scale (the Density Playground's `chatTextScale`) sets the density's part exactly.
        let densityBody = Metrics.tokens.tokens["chatTextScale"].map { drawn * CGFloat($0) } ?? max(Metrics.tokens.bodySize, drawn)
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? densityBody
        return body / drawn * interfaceScale
    }
    /// The person's own text scale for the chats, over Default's: Text Size and a chrome font size set in Settings,
    /// never the density. The Chief chat's native transcript draws at it, so its size is Default's at every density.
    static var chatUserScale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let drawn = DensityPreset.cozy.tokens.bodySize
        let body = DesignSettings.shared.overrides[.chromeFontSize] ?? drawn
        return body / drawn * interfaceScale
    }
    /// The Home (iMessage-style) chat's size from the density: 1 at every built-in, which never scales it, or a custom
    /// density's `homeTextScale` (the Density Playground). The Chief chat's transcript zooms by it with Agent Chat Zoom.
    static var homeChatDensityScale: CGFloat { Metrics.tokens.tokens["homeTextScale"].map { CGFloat($0) } ?? 1 }
}
