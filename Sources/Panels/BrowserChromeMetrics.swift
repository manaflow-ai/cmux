import CoreGraphics

enum BrowserNavigationToolbarIcon: CaseIterable, Equatable {
    case back
    case forward
    case reload
    case stop

    var symbolName: String {
        switch self {
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .reload: return "arrow.clockwise"
        case .stop: return "xmark"
        }
    }

    /// SF Symbol intrinsic sizes at the legacy 12pt medium-weight browser
    /// navigation size. The toolbar uses the largest measured edge across all
    /// variants so the reload button does not resize when it flips to stop and
    /// the back/forward buttons share that same optical box.
    var measuredReferenceSize: CGSize {
        switch self {
        case .back, .forward:
            CGSize(width: 9, height: 13)
        case .reload:
            CGSize(width: 13, height: 15)
        case .stop:
            CGSize(width: 13, height: 12)
        }
    }

    var measuredReferenceMaxEdge: CGFloat {
        max(measuredReferenceSize.width, measuredReferenceSize.height)
    }

    static func reloadOrStop(isLoading: Bool) -> BrowserNavigationToolbarIcon {
        isLoading ? .stop : .reload
    }
}

/// Derives the browser top-chrome sizes (omnibar text, navigation glyphs,
/// toolbar icon buttons) from the user's tab bar font size so the whole top
/// chrome — tabs plus the browser toolbar — renders at one consistent scale.
///
/// Every size is a pure multiple of a reference base constant. At
/// ``referenceFontSize`` the scale is exactly `1`; larger or smaller tab bar
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

    /// Square raster size for every back/forward/reload/stop navigation glyph.
    /// Base `15`, the largest measured intrinsic edge among the four symbols at
    /// the legacy 12pt medium-weight setting.
    var navigationIconRasterSize: CGFloat { scaled(Self.navigationIconReferenceRasterSize) }

    /// Point size for the HTTPS lock badge in the omnibar. Base `10`.
    var secureBadgeFontSize: CGFloat { scaled(10) }

    /// Point size for the right-side accessory glyphs (screenshot, cursor grab,
    /// profile, theme, developer tools). Base `11`.
    var accessoryIconFontSize: CGFloat { scaled(11) }

    /// Square edge of the right-side accessory icon buttons. Base `22`.
    var buttonIconSize: CGFloat { scaled(22) }

    /// Square hit target of the back/forward/reload buttons. Base `26`.
    var buttonHitSize: CGFloat { scaled(26) }

    func navigationIconRasterSize(for _: BrowserNavigationToolbarIcon) -> CGFloat {
        return navigationIconRasterSize
    }

    private static var navigationIconReferenceRasterSize: CGFloat {
        BrowserNavigationToolbarIcon.allCases
            .map(\.measuredReferenceMaxEdge)
            .max() ?? 12
    }

    private func scaled(_ base: CGFloat) -> CGFloat { base * scale }
}
