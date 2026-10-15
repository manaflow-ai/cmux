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

    /// Inset of the Chromium permission prompt bar from the page edges. Base `8`.
    var promptBarInset: CGFloat { scaled(8) }

    /// Narrowest the permission prompt bar gets (a narrower page narrows it further). Base `320`.
    var promptBarMinWidth: CGFloat { scaled(320) }

    /// Widest the permission prompt bar gets. Base `480`.
    var promptBarMaxWidth: CGFloat { scaled(480) }

    /// Corner radius of the permission prompt bar (matches the omnibar). Base `10`.
    var promptBarCornerRadius: CGFloat { scaled(10) }

    /// Padding inside the permission prompt bar. Base `10`.
    var promptBarPadding: CGFloat { scaled(10) }

    /// Point size of the permission prompt bar's capability glyph. Base `14`.
    var promptBarIconFontSize: CGFloat { scaled(14) }

    /// Point size of the permission prompt bar's message. Base `13`.
    var promptBarMessageFontSize: CGFloat { scaled(13) }

    /// Point size of the permission prompt bar's button titles. Base `12`.
    var promptBarButtonFontSize: CGFloat { scaled(12) }

    /// Shadow radius under the permission prompt bar. Base `6`.
    var promptBarShadowRadius: CGFloat { scaled(6) }

    /// Shadow drop under the permission prompt bar. Base `2`.
    var promptBarShadowOffsetY: CGFloat { scaled(2) }

    /// Height of the permission prompt bar's buttons. Base `22`.
    var promptBarButtonHeight: CGFloat { scaled(22) }

    /// The permission prompt bar's width for a page `pageWidth` wide:
    /// three quarters of the page, clamped to the min/max widths and never
    /// wider than the page minus its insets.
    func promptBarWidth(pageWidth: CGFloat) -> CGFloat {
        let preferred = min(max(pageWidth * 0.75, promptBarMinWidth), promptBarMaxWidth)
        return max(0, min(preferred, pageWidth - promptBarInset * 2))
    }

    private func scaled(_ base: CGFloat) -> CGFloat { base * scale }
}
