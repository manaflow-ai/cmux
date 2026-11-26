import AppKit
import CoreText

extension TerminalFontSetting {
    /// Installed fixed-pitch families the terminal accepts, sorted, listed once per launch: the
    /// Settings page's and the palette's font menus.
    @MainActor public static let installedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.map { CTFontCopyFamilyName(CTFontCreateWithName($0 as CFString, 0, nil)) as String })
            .filter { TerminalFontSetting().isValidFamily($0) && !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()
}
