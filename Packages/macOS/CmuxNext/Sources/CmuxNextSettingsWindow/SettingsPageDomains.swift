import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// The value domains the Settings page offers in menus, listed once per launch.
@MainActor
package struct SettingsPageDomains {
    package init() {}
    /// Installed fixed-pitch families the terminal accepts, sorted.
    package static let fontFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: TypeScale.body)?.familyName })
            .filter { TerminalFontSetting().isValidFamily($0) && !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// The sounds in /System/Library/Sounds.
    package static let sounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()
}
