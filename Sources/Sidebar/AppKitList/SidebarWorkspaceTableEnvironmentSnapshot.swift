import CmuxFoundation
import SwiftUI

private struct SidebarPlatformListHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside cells hosted by the AppKit sidebar table. Rows read it to
    /// skip the SwiftUI drag/drop mounts that the table owns natively
    /// (row drag sources and per-row bonsplit drop targets).
    var sidebarPlatformListHosted: Bool {
        get { self[SidebarPlatformListHostedKey.self] }
        set { self[SidebarPlatformListHostedKey.self] = newValue }
    }
}

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
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
            .environment(\.sidebarPlatformListHosted, true)
            .environment(\.sidebarLazyContractProbe, lazyContractProbe)
#else
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.sidebarPlatformListHosted, true)
#endif
    }
}
