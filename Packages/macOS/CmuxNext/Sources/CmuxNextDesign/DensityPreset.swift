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
        // Default's omnibar is Compact's (``omnibarScaleFactor``).
        if self == .cozy {
            for (key, value) in Self.compact.tokens.tokens where Self.isOmnibarToken(key) { sizes[key] = value }
        }
        return DensityTokens(id: rawValue, name: name, level: (Self.referenceTokens.level + 3) * t - 3,
                             spacing: Self.referenceTokens.spacing * t,
                             fontSize: Self.referenceTokens.fontSize.map { $0 * t }, tokens: sizes)
    }

    /// The factor the browser toolbar row (the omnibar and its toolbar glyphs) scales Default's reference by: Compact's
    /// at Default (Lucas 2026-11-17: "the default omnibar should be the same as compact omnibar, we should match them
    /// exactly"), each density's own elsewhere. The toolbar buttons follow the omnibar's height.
    public var omnibarScaleFactor: Double { self == .cozy ? Self.compact.scaleFactor : scaleFactor }

    /// The sizes ``omnibarScaleFactor`` scales: every `omnibar*` token and the toolbar glyphs beside the bar.
    static func isOmnibarToken(_ key: String) -> Bool { key.hasPrefix("omnibar") || key == "toolbarGlyphSize" }

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
        "omnibarCornerRadius": 8, "omnibarPopupCornerRadius": 12, "omnibarPopupRowCornerRadius": 8,
        // Helium's toolbar at Compact (its reference, Lucas 2026-11-16): the reload glyph draws 14 px tall, the omnibar's
        // search glyph 12 px and its text's capitals 10 px; Default is those over Compact's 0.9. The glyphs' ink fills
        // about 0.617 (toolbar) and 0.697 (search) of their boxes, measured in HeliumToolbarSizeTests. macOS font smoothing
        // grows the capitals about 0.31 pt, so the font's own are that much under 10: the H then fills exactly 20 rows at 2x,
        // with no lit row above it (Lucas 2026-11-17: at 0.14 a 21st row lit 39% and the H read taller than 10).
        "toolbarGlyphSize": 14 / 0.9 / 0.617,
        "omnibarHeight": 29, "omnibarFontSize": (10 - 0.31) / 0.70459 / 0.9, "omnibarLineBoxBaseline": 1,
        "omnibarButtonSpacing": 3, "omnibarEdgeInset": 2, "omnibarFieldTrailingGap": 5,
        "omnibarTrailingPadding": 8,
        "omnibarTrailingIconSize": 18, "omnibarIconViewSize": 25, "omnibarIconSize": 12 / 0.9 / 0.697,
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
