import CmuxAppKitSupportUI
import CmuxFoundation

/// Value-only appearance state forwarded into each native table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: WindowChromeColorScheme
    let globalFontMagnificationPercent: Int

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }
}
