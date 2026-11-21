public import CoreGraphics

/// Built-in densities share Default's proportions and keep the owner's row heights.
public nonisolated enum DensityPreset: String, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case cozy
    case comfortable
    case spacious

    /// The size multiplier relative to Default.
    public var scaleFactor: Double {
        switch self {
        case .ultraCompact: 0.8
        case .compact: 0.9
        case .cozy: 1
        case .comfortable: 1.1
        case .spacious: 1.2
        }
    }

    private var rowHeight: Double {
        switch self {
        case .ultraCompact: 24
        case .compact: 28
        case .cozy: 30
        case .comfortable: 32
        case .spacious: 36
        }
    }

    private var name: String {
        switch self {
        case .ultraCompact: "Ultra-compact"
        case .compact: "Compact"
        case .cozy: "Default"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }

    /// Default's sizes times one factor, apart from the specified row heights.
    public var tokens: DensityTokens {
        let t = scaleFactor
        // Baseline flags are ratios, not point sizes. Composer zoom is the shared factor.
        let fonts = ["tabTitleSize", "sidebarTitleSize", "omnibarFontSize"]
        var sizes = Self.referenceTokens.tokens.mapValues { Double(DensityTokens.half($0 * t)) }
        for key in fonts {
            sizes[key] = Self.referenceTokens.tokens[key].map { $0 * t }
        }
        for key in ["sidebarLineBoxBaseline", "omnibarLineBoxBaseline"] {
            sizes[key] = Self.referenceTokens.tokens[key]
        }
        sizes["densityScale"] = t
        sizes["composerZoom"] = t
        sizes["sidebarRowHeight"] = rowHeight - Double(DensityTokens.half(2 * t))
        sizes["browserRowHeight"] = rowHeight
        sizes["tabStripHeight"] = rowHeight + 2 * Double(DensityTokens.half(3 * t))
        // Default and the densities above it take Default's Chrome spacing times their factor (Lucas 2026-11-20: "make sure
        // that densities after default have similar spacing to default (but proportionally)"): the strip padding (Default's
        // 5 pt, Chrome's tab top) and the omnibar row's gap (Chrome's 6 pt, ``chromeToolbarGap``). Ultra-compact and Compact
        // keep Default-times-their-factor's 3 pt.
        if t >= 1 {
            // Spacious's 37.5 pt bar takes half-point gaps, 6.5 and 7.5 (Lucas 2026-11-21): with 6 and 7 its toolbar row
            // put the bar where AppKit drew it 0.5 pt taller (`OmnibarDensityTests.nothingClipsOrOverlaps`).
            let nudge = self == .spacious ? Self.spaciousGapNudge : 0
            let padding = Double(DensityTokens.half(Self.defaultStripPadding * t)) + nudge
            sizes["browserRowGap"] = padding
            sizes["tabStripHeight"] = rowHeight + 2 * padding
            sizes["omnibarRowGap"] = Double(DensityTokens.half(Self.chromeToolbarGap * t)) + nudge
        }
        // Compact's tabs sit a point further from the omnibar than their strip padding (Lucas 2026-11-20: "give compact 1
        // more px of bottom padding below the tab"): 3.5 pt from the tab pills to the bar, 2.5 above the tabs and under the bar.
        if self == .compact { sizes["tabToOmnibarGap"] = Double(DensityTokens.half(3 * t)) + Self.compactTabToOmnibarExtra }
        // Default's omnibar is Compact's (``omnibarScaleFactor``).
        if self == .cozy {
            for (key, value) in Self.compact.tokens.tokens where Self.isOmnibarToken(key) { sizes[key] = value }
            // Default's bar is Chrome's location bar (Lucas 2026-11-17: "for chrome the omnibar should be 34px tall
            // (chrome = default, but still same font size)"), rounded at Helium's 8 on 28. Its icons and insets stay Compact's.
            // Its toolbar buttons and star plate keep Compact's padding around Compact's glyphs (Lucas 2026-11-18: "they seem
            // to be quite big? ... don't have an insane amount of padding"): Compact's 28 pt buttons, centered on the
            // 34 pt bar, and a 28 pt plate for its 16 pt star (Compact's 24 for 13.5).
            sizes["omnibarButtonSize"] = sizes["omnibarHeight"]
            sizes["omnibarStarPlateSize"] = Self.defaultStarPlateSize
            sizes["omnibarHeight"] = Self.chromeOmnibarHeight
            sizes["omnibarCornerRadius"] = Double(DensityTokens.half(Self.chromeOmnibarHeight * 8 / 28))
            // Its URL capitals are a point over Compact's 10 (Lucas 2026-11-17: "for default our font size has to be 1px
            // taller in height"), with the smoothing's 0.31 pt as in the reference below.
            sizes["omnibarFontSize"] = (Self.defaultOmnibarCapHeight - 0.31) / 0.70459
            // Its search glyph is a little taller than Compact's too (Lucas 2026-11-17: "maybe make the search icon 1px
            // taller too for default"; 2026-11-18: "can be 0.5px shorter in height"): Compact's box plus a point, the
            // half-point box nearest a glyph 0.5 pt under the first one's 13 pt.
            if let icon = sizes["omnibarIconSize"] { sizes["omnibarIconSize"] = icon + 1 }
        }
        sizes["omnibarStarGlyphSize"] = Self.starGlyphSides[self]
        return DensityTokens(id: rawValue, name: name, level: (Self.referenceTokens.level + 3) * t - 3,
                             spacing: Self.referenceTokens.spacing * t,
                             fontSize: Self.referenceTokens.fontSize.map { $0 * t }, tokens: sizes)
    }

    /// The factor the browser toolbar row (the omnibar and its toolbar glyphs) scales Default's reference by: Compact's
    /// at Default (Lucas 2026-11-17: "the default omnibar should be the same as compact omnibar, we should match them
    /// exactly"), each density's own elsewhere. The toolbar buttons follow the omnibar's height. Default's bar alone is
    /// Chrome's (``chromeOmnibarHeight``).
    public var omnibarScaleFactor: Double { self == .cozy ? Self.compact.scaleFactor : scaleFactor }

    /// The sizes ``omnibarScaleFactor`` scales: every `omnibar*` token and the toolbar glyphs beside the bar.
    static func isOmnibarToken(_ key: String) -> Bool { key.hasPrefix("omnibar") || key == "toolbarGlyphSize" }

    /// What Spacious's strip padding and omnibar row gap add to Default's times 1.2, so its half-point bar keeps whole-point rows.
    static let spaciousGapNudge: Double = 0.5
    /// What Compact's gap from its tabs to the omnibar adds to its strip padding (`tabToOmnibarGap`).
    static let compactTabToOmnibarExtra: Double = 1
    /// Default's location bar: Chrome's 34 pt (`kLocationBarHeight` in Chrome's layout constants).
    static let chromeOmnibarHeight: Double = 34
    /// Default's room above and below its location bar (Lucas 2026-11-20: "match chrome to be EXACTLY the same as chromium
    /// ... top-padding 6px bottom padding 6px"), Comfortable and Spacious that times their factor: Chrome's 6 pt (`TOOLBAR_INTERIOR_MARGIN`'s vertical inset in
    /// Chrome's layout constants), the bar's 34 pt in a 46 pt toolbar.
    static let chromeToolbarGap: Double = 6
    /// Default's strip padding: 5 pt above, beside and under its tabs, 2 over Default-times-1's 3 (Lucas 2026-11-20: "make
    /// the top of the tabs 5px (so 2 more px)"); Comfortable and Spacious take it times their factor.
    static let defaultStripPadding: Double = 5
    /// Default's URL capitals: 11 pt, a point over Compact's 10.
    static let defaultOmnibarCapHeight: Double = 11
    /// Default's star plate: its 16 pt star with Compact's padding (24 pt around 13.5), on whole pixels.
    static let defaultStarPlateSize: Double = 28
    /// Each built-in's bookmark star side. The star scales with the bar from Compact's 13.5 pt of ink (Lucas 2026-11-18:
    /// "the star/favourite icon should be 12px height", "make the star 2px bigger", "0.5px smaller"): 12, 13.5, 16.5 and
    /// 18 pt at Ultra-compact, Compact, Comfortable and Spacious ("make sure the star scales up in comfortable and spacious
    /// proportionally too. and that its pixel perfect"). Default's is Chrome's 15 pt and 1 more, 16 ("for default, we
    /// want to chrome parity match", "for default decrease by 1px"). Each side is the half-point one that draws exactly
    /// twice its ink in rows at 2x with whole edge rows, measured (OmnibarTrailingGlyphsTests): the glyph's pixel grid
    /// makes a reference times the factor miss by a row (28.5 and 31.5 at Comfortable and Spacious). No half-point side
    /// draws 24 or 32 whole rows, so Ultra-compact's 21 and Default's 28 keep a faint top row.
    static let starGlyphSides: [DensityPreset: Double] = [.ultraCompact: 21, .compact: 23.5, .cozy: 28, .comfortable: 29.5, .spacious: 32]

    // The unscaled reference also resolves sizes that use the legacy compact/comfortable pairs.
    static let referenceTokens = DensityTokens(id: cozy.rawValue, name: "Default", level: 0.5, fontSize: 14,
                                               tokens: reference)

    // Default's sizes, the reference every density scales.
    private static let reference: [String: Double] = [
        "sidebarRowHeight": 28, "browserRowHeight": 30, "browserRowGap": 3, "tabStripHeight": 36,
        "tabTitleSize": 14, "sidebarTitleSize": 14, "chatEditorMin": 35,
        "sidebarRowInset": 6, "sidebarContentInset": 7, "sidebarLineBoxBaseline": 1,
        "sidebarIconColumn": 16.5, "sidebarIconGap": 7,
        "tabIconSize": 16.5, "tabIconTitleGap": 7, "tabGap": 3, "tabMaxWidth": 201,
        "rowCornerRadius": 9, "tabCornerRadius": 9,
        "omnibarCornerRadius": 8 / 0.9, "omnibarPopupCornerRadius": 12, "omnibarPopupRowCornerRadius": 8,
        // Helium's toolbar at Compact (its reference, Lucas 2026-11-16): the location bar is 28 pt tall with 8 pt corners
        // (Lucas 2026-11-17: ours was 26), the reload glyph draws 14 px tall, the omnibar's
        // search glyph 12 px and its text's capitals 10 px; Default is those over Compact's 0.9. The glyphs' ink fills
        // about 0.617 (toolbar) and 0.697 (search) of their boxes, measured in HeliumToolbarSizeTests. macOS font smoothing
        // grows the capitals about 0.31 pt, so the font's own are that much under 10: the H then fills exactly 20 rows at 2x,
        // with no lit row above it (Lucas 2026-11-17: at 0.14 a 21st row lit 39% and the H read taller than 10).
        "toolbarGlyphSize": 14 / 0.9 / 0.617,
        "omnibarHeight": 28 / 0.9, "omnibarFontSize": (10 - 0.31) / 0.70459 / 0.9, "omnibarLineBoxBaseline": 1,
        "omnibarButtonSpacing": 3, "omnibarEdgeInset": 2, "omnibarFieldTrailingGap": 5,
        "omnibarTrailingPadding": 8,
        "omnibarTrailingIconSize": 18, "omnibarIconViewSize": 25, "omnibarIconSize": 12 / 0.9 / 0.697,
        // Compact's Extensions puzzle draws 16 pt of ink, measured from the first lit pixel row to the last at 2x (Lucas
        // 2026-11-18: "the extensions icon on compact should be 2px taller. its currently at 14px", "pixel perfect"): the
        // half-point side that draws exactly 32 rows is 27 pt (both edge rows 97% lit or more). The bookmark star's sides
        // are ``starGlyphSides``.
        // The ⋮ is Helium's and Chrome's: their 3 dots on a 20 pt side, 12 pt tall and 3 pt wide.
        "omnibarExtensionsGlyphSize": 27 / 0.9, "omnibarMoreGlyphSize": 20 / 0.9,
        "omnibarIconLeading": 2, "omnibarTextGap": 5, "omnibarPopupTopOutset": 3, "omnibarPopupSideOutset": 7,
        "omnibarPopupRowGap": 2, "omnibarPopupBottomPadding": 4,
    ]
}

public extension DensityTokens {
    /// An exact font token (`tabTitleSize`, `sidebarTitleSize`, `omnibarFontSize`) at this density's body size. A
    /// built-in's tokens are exact at its own body size; a custom density made from one scales them with its own
    /// `fontSize`, so a larger body size grows the titles and the URL text with it.
    nonisolated func fontToken(_ key: String) -> CGFloat? {
        guard let raw = tokens[key] else { return nil }
        let exact = CGFloat(raw)
        guard let basedOn, let preset = DensityPreset(rawValue: basedOn) else { return exact }
        let presetBody = preset.tokens.bodySize
        return presetBody > 0 ? exact * bodySize / presetBody : exact
    }
}
