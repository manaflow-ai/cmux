import AppKit
import CmuxFoundation
import CoreGraphics
import SwiftUI

/// Immutable presentation environment shared by hosted and pure-AppKit table cells.
/// The initializer projects the supplied SwiftUI environment immediately; it
/// never retains environment objects across the sidebar's lazy-list boundary.
@MainActor
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
    let globalFontMagnificationPercent: Int
    /// Concrete semantic colors resolved from the table's SwiftUI environment.
    /// Pure-AppKit rows consume these instead of re-reading their backing
    /// view's effective appearance during focus or reparenting churn.
    let primaryTextColor: NSColor
    let secondaryTextColor: NSColor
    /// Concrete system tint used by AppKit unread badges.
    /// Resolving it at the table boundary makes an accent-color change part of
    /// the same invalidation contract as the semantic text palette.
    let accentColor: NSColor
    /// Settable base AppKit appearance matching the table's SwiftUI color scheme.
    /// AppKit's accessibility-high-contrast names are match-only appearances.
    let appKitAppearance: NSAppearance?
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
#endif

#if DEBUG
    init(
        environment: EnvironmentValues,
        globalFontMagnificationPercent: Int,
        lazyContractProbe: SidebarLazyContractProbe,
        systemAccentColor: NSColor? = nil
    ) {
        let colors = Self.resolvedTextColors(in: environment)
        let appKitAppearance = Self.appKitAppearance(for: environment.colorScheme)
        self.colorScheme = environment.colorScheme
        self.colorSchemeContrast = environment.colorSchemeContrast
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.primaryTextColor = colors.primary
        self.secondaryTextColor = colors.secondary
        self.accentColor = Self.resolvedSystemAccentColor(
            systemAccentColor ?? .controlAccentColor,
            appearance: appKitAppearance
        )
        self.appKitAppearance = appKitAppearance
        self.lazyContractProbe = lazyContractProbe
    }
#else
    init(
        environment: EnvironmentValues,
        globalFontMagnificationPercent: Int,
        systemAccentColor: NSColor? = nil
    ) {
        let colors = Self.resolvedTextColors(in: environment)
        let appKitAppearance = Self.appKitAppearance(for: environment.colorScheme)
        self.colorScheme = environment.colorScheme
        self.colorSchemeContrast = environment.colorSchemeContrast
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.primaryTextColor = colors.primary
        self.secondaryTextColor = colors.secondary
        self.accentColor = Self.resolvedSystemAccentColor(
            systemAccentColor ?? .controlAccentColor,
            appearance: appKitAppearance
        )
        self.appKitAppearance = appKitAppearance
    }
#endif

    nonisolated func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && colorSchemeContrast == other.colorSchemeContrast
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
            && primaryTextColor == other.primaryTextColor
            && secondaryTextColor == other.secondaryTextColor
            && accentColor == other.accentColor
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        // SwiftUI exposes contrast as read-only. Independent NSHostingViews
        // inherit the same system contrast directly; the stored value and
        // concrete palette invalidate and repaint the pure-AppKit cells.
#if DEBUG
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.sidebarLazyContractProbe, lazyContractProbe)
#else
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
#endif
    }

    private static func resolvedTextColors(
        in environment: EnvironmentValues
    ) -> (primary: NSColor, secondary: NSColor) {
        let fallbackPrimary = environment.colorScheme == .dark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let fallbackSecondaryAlpha: CGFloat = environment.colorSchemeContrast == .increased ? 0.75 : 0.55
        return (
            appKitColor(
                from: Color.primary.resolve(in: environment),
                fallback: fallbackPrimary
            ),
            appKitColor(
                from: Color.secondary.resolve(in: environment),
                fallback: fallbackPrimary.withAlphaComponent(fallbackSecondaryAlpha)
            )
        )
    }

    private static func appKitAppearance(for colorScheme: ColorScheme) -> NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    private static func resolvedSystemAccentColor(
        _ color: NSColor,
        appearance: NSAppearance?
    ) -> NSColor {
        guard let appearance else {
            return color.usingColorSpace(.sRGB) ?? color
        }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private static func appKitColor(
        from resolved: Color.Resolved,
        fallback: NSColor
    ) -> NSColor {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cgColor = CGColor(
                  colorSpace: colorSpace,
                  components: [
                      CGFloat(resolved.linearRed),
                      CGFloat(resolved.linearGreen),
                      CGFloat(resolved.linearBlue),
                      CGFloat(resolved.opacity),
                  ]
              ),
              let color = NSColor(cgColor: cgColor) else {
            return fallback
        }
        return color
    }
}
