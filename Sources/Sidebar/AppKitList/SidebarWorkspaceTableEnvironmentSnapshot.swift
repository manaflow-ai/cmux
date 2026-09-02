import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let chromePalette: ChromePalette
    let globalFontMagnificationPercent: Int
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe

    init(
        colorScheme: ColorScheme,
        chromePalette: ChromePalette? = nil,
        globalFontMagnificationPercent: Int,
        lazyContractProbe: SidebarLazyContractProbe
    ) {
        self.colorScheme = colorScheme
        self.chromePalette = chromePalette ?? ChromePalette.resolve(
            theme: .default,
            colorScheme: colorScheme == .dark ? .dark : .light
        )
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
        self.lazyContractProbe = lazyContractProbe
    }
#else
    init(
        colorScheme: ColorScheme,
        chromePalette: ChromePalette? = nil,
        globalFontMagnificationPercent: Int
    ) {
        self.colorScheme = colorScheme
        self.chromePalette = chromePalette ?? ChromePalette.resolve(
            theme: .default,
            colorScheme: colorScheme == .dark ? .dark : .light
        )
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
    }
#endif

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && chromePalette == other.chromePalette
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
#if DEBUG
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.chromePalette, chromePalette)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.sidebarLazyContractProbe, lazyContractProbe)
#else
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.chromePalette, chromePalette)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
#endif
    }
}
