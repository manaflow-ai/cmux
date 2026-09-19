import CmuxFoundation
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
    /// Icon rail vs regular rows; a flip reconfigures and re-measures every
    /// row through the normal apply pass.
    var columnDisplayMode: SidebarColumnDisplayMode = .regular
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
#endif

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
            && columnDisplayMode == other.columnDisplayMode
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
}
