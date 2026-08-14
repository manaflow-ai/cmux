import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let chromePalette: ChromePalette = ChromePalette.resolve(theme: .default, colorScheme: .light)
    let globalFontMagnificationPercent: Int
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
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
