import CoreGraphics

/// Derives the browser top-chrome sizes (omnibar text, navigation glyphs,
/// toolbar icon buttons) from the user's tab bar font size so the whole top
/// chrome — tabs plus the browser toolbar — renders at one consistent scale.
///
/// Every size is a pure multiple of a legacy base constant. At
/// ``referenceFontSize`` the scale is exactly `1`, so the chrome is
/// byte-identical to the previously hardcoded layout; larger or smaller tab bar
/// font sizes scale the chrome proportionally. The derived scale is clamped to
/// ``minimumScale``...``maximumScale`` so a malformed config value can never
/// blow the toolbar up or collapse it.
///
/// The type is a pure value with no I/O, so the derivation is unit-testable
/// without launching the app: construct it with a font size and read the
/// computed sizes.
struct BrowserChromeMetrics: Equatable {
    /// The tab bar font size the chrome scales against, in points.
    let tabBarFontSize: CGFloat

    /// The tab bar font size at which the chrome matches its legacy hardcoded
    /// sizes (scale `1`). Anchored to the shipped default so "default size looks
    /// unchanged" holds even if the default is later retuned.
    static let referenceFontSize: CGFloat = GhosttyConfig.defaultSurfaceTabBarFontSize

    /// Lower bound on the derived scale; guards against a near-zero config value.
    static let minimumScale: CGFloat = 0.5

    /// Upper bound on the derived scale; guards against an absurd config value.
    static let maximumScale: CGFloat = 2.0

    /// Multiplier applied to every legacy base size. `1` at ``referenceFontSize``.
    var scale: CGFloat {
        guard tabBarFontSize.isFinite, tabBarFontSize > 0 else { return 1 }
        let raw = tabBarFontSize / Self.referenceFontSize
        return min(max(raw, Self.minimumScale), Self.maximumScale)
    }

    /// Point size for the omnibar URL text field. Base `12`.
    var omnibarFontSize: CGFloat { scaled(12) }

    /// Height of the omnibar text field so taller text is not clipped. Base `18`.
    var omnibarFieldHeight: CGFloat { scaled(18) }

    /// Point size for the back/forward/reload navigation glyphs. Base `12`.
    var navigationIconFontSize: CGFloat { scaled(12) }

    /// Point size for the HTTPS lock badge in the omnibar. Base `10`.
    var secureBadgeFontSize: CGFloat { scaled(10) }

    /// Point size for the right-side accessory glyphs (screenshot, cursor grab,
    /// profile, theme, developer tools). Base `11`.
    var accessoryIconFontSize: CGFloat { scaled(11) }

    /// Square edge of the right-side accessory icon buttons. Base `22`.
    var buttonIconSize: CGFloat { scaled(22) }

    /// Square hit target of the back/forward/reload buttons. Base `26`.
    var buttonHitSize: CGFloat { scaled(26) }

    /// Vertical padding of the Chromium permission prompt strip (spec §4). Base `6`.
    var promptStripVerticalPadding: CGFloat { scaled(6) }

    /// Horizontal padding of the permission prompt strip. Base `8`.
    var promptStripHorizontalPadding: CGFloat { scaled(8) }

    /// Minimum height of the permission prompt strip. Base `32`.
    var promptStripMinHeight: CGFloat { scaled(32) }

    /// Space between the strip's glyph, message and buttons. Base `8`.
    var promptStripSpacing: CGFloat { scaled(8) }

    /// Pane width under which the strip's buttons wrap to a second row
    /// (spec §4: 420 pt of pane, not scaled).
    static let promptStripNarrowPaneWidth: CGFloat = 420

    /// Point size of the permission prompt's capability glyph. Base `14`.
    var promptBarIconFontSize: CGFloat { scaled(14) }

    /// Point size of the permission prompt's message (design review: matches
    /// the omnibar's text). Base `12`.
    var promptBarMessageFontSize: CGFloat { scaled(12) }

    /// Point size of the permission prompt's button titles. Base `12`.
    var promptBarButtonFontSize: CGFloat { scaled(12) }

    /// Height of the permission prompt's buttons. Base `22`.
    var promptBarButtonHeight: CGFloat { scaled(22) }

    /// Glyph size of a full-page recovery view (Chromium error, crash). Base `28`.
    var recoveryIconSize: CGFloat { scaled(28) }

    /// Title size of a full-page recovery view. Base `17`.
    var recoveryTitleFontSize: CGFloat { scaled(17) }

    /// Body size of a full-page recovery view. Base `13`.
    var recoveryBodyFontSize: CGFloat { scaled(13) }

    /// Caption size (error code line) of a full-page recovery view. Base `11`.
    var recoveryCaptionFontSize: CGFloat { scaled(11) }

    /// Widest text column of a full-page recovery view. Base `420`.
    var recoveryMaxWidth: CGFloat { scaled(420) }

    /// Space between the parts of a full-page recovery view. Base `10`.
    var recoverySpacing: CGFloat { scaled(10) }

    /// How far a recovery view sits above the page's center: one toolbar
    /// height (hit target plus the row's vertical padding). Base `34`.
    var recoveryVerticalLift: CGFloat { scaled(34) }

    private func scaled(_ base: CGFloat) -> CGFloat { base * scale }
}
