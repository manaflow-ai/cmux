import CmuxFoundation
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted Vault row.
struct SessionIndexTableEnvironmentSnapshot {
    static let fallback = SessionIndexTableEnvironmentSnapshot(
        colorScheme: .light,
        globalFontMagnificationPercent: GlobalFontMagnification.defaultPercent
    )

    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
    }
}
