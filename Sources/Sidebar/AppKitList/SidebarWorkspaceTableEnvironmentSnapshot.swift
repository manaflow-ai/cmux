import SwiftUI

/// Value-only presentation environment used to build native table-row models.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }
}
