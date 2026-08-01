import AppKit
import CmuxFoundation
import SwiftUI

/// Immutable presentation environment shared by hosted and pure-AppKit table cells.
@MainActor
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
    /// Concrete semantic colors resolved from the table's explicit scheme.
    /// Pure-AppKit rows consume these instead of re-reading their backing
    /// view's effective appearance during focus or reparenting churn.
    let primaryTextColor: NSColor
    let secondaryTextColor: NSColor
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
#endif

#if DEBUG
    init(
        colorScheme: ColorScheme,
        globalFontMagnificationPercent: Int,
        lazyContractProbe: SidebarLazyContractProbe
    ) {
        let colors = Self.resolvedTextColors(for: colorScheme)
        self.colorScheme = colorScheme
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.primaryTextColor = colors.primary
        self.secondaryTextColor = colors.secondary
        self.lazyContractProbe = lazyContractProbe
    }
#else
    init(
        colorScheme: ColorScheme,
        globalFontMagnificationPercent: Int
    ) {
        let colors = Self.resolvedTextColors(for: colorScheme)
        self.colorScheme = colorScheme
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.primaryTextColor = colors.primary
        self.secondaryTextColor = colors.secondary
    }
#endif

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
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
        for colorScheme: ColorScheme
    ) -> (primary: NSColor, secondary: NSColor) {
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let fallbackPrimary = colorScheme == .dark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let fallbackSecondary = fallbackPrimary.withAlphaComponent(0.55)
        // Aqua and Dark Aqua are built-in AppKit appearances. Resolve while
        // the requested one is current so the returned sRGB colors are no
        // longer dynamic and cannot follow a transient backing view later.
        guard let appearance = NSAppearance(named: appearanceName) else {
            return (fallbackPrimary, fallbackSecondary)
        }
        var primary = fallbackPrimary
        var secondary = fallbackSecondary
        appearance.performAsCurrentDrawingAppearance {
            primary = NSColor.labelColor.usingColorSpace(.sRGB) ?? primary
            secondary = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? secondary
        }
        return (primary, secondary)
    }
}
