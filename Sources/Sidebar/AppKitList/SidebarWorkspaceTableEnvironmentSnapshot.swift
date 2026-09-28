import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
#endif
    /// macOS Display accessibility settings the AppKit rows paint with.
    var displayAccessibility: DisplayAccessibilityOptions = .standard

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
            && displayAccessibility == other.displayAccessibility
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
