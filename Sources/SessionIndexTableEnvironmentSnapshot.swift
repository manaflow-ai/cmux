import CmuxAppKitSupportUI
import CmuxFoundation

/// Value-only appearance state forwarded into each native Vault row.
struct SessionIndexTableEnvironmentSnapshot {
    static let fallback = SessionIndexTableEnvironmentSnapshot(
        colorScheme: .light,
        globalFontMagnificationPercent: GlobalFontMagnification.defaultPercent
    )

    let colorScheme: WindowChromeColorScheme
    let globalFontMagnificationPercent: Int

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
    }
}
