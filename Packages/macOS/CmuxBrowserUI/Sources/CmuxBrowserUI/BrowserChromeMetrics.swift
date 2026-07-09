public import CoreGraphics
import CmuxFoundation

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
public struct BrowserChromeMetrics: Equatable {
    /// The tab bar font size the chrome scales against, in points.
    public let tabBarFontSize: CGFloat

    /// Creates the metrics for a given tab bar font size.
    public init(tabBarFontSize: CGFloat) {
        self.tabBarFontSize = tabBarFontSize
    }

    /// The tab bar font size at which the chrome matches its legacy hardcoded
    /// sizes (scale `1`). Anchored to the shipped default so "default size looks
    /// unchanged" holds even if the default is later retuned.
    public static let referenceFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize)

    /// Lower bound on the derived scale; guards against a near-zero config value.
    public static let minimumScale: CGFloat = 0.5

    /// Upper bound on the derived scale; guards against an absurd config value.
    public static let maximumScale: CGFloat = 2.0

    /// Multiplier applied to every legacy base size. `1` at ``referenceFontSize``.
    public var scale: CGFloat {
        guard tabBarFontSize.isFinite, tabBarFontSize > 0 else { return 1 }
        let raw = tabBarFontSize / Self.referenceFontSize
        return min(max(raw, Self.minimumScale), Self.maximumScale)
    }

    /// Point size for the omnibar URL text field. Base `12`.
    public var omnibarFontSize: CGFloat { scaled(12) }

    /// Height of the omnibar text field so taller text is not clipped. Base `18`.
    public var omnibarFieldHeight: CGFloat { scaled(18) }

    /// Point size for the back/forward/reload navigation glyphs. Base `12`.
    public var navigationIconFontSize: CGFloat { scaled(12) }

    /// Point size for the HTTPS lock badge in the omnibar. Base `10`.
    public var secureBadgeFontSize: CGFloat { scaled(10) }

    /// Point size for the right-side accessory glyphs (screenshot, cursor grab,
    /// profile, theme, developer tools). Base `11`.
    public var accessoryIconFontSize: CGFloat { scaled(11) }

    /// Square edge of the right-side accessory icon buttons. Base `22`.
    public var buttonIconSize: CGFloat { scaled(22) }

    /// Square hit target of the back/forward/reload buttons. Base `26`.
    public var buttonHitSize: CGFloat { scaled(26) }

    private func scaled(_ base: CGFloat) -> CGFloat { base * scale }
}
