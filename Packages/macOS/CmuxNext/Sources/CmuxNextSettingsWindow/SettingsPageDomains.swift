import AppKit
import CmuxNextSettings
import Foundation

/// The value domains the Settings page offers in menus, listed once per launch.
@MainActor
public struct SettingsPageDomains {
    public init() {}

    /// Installed fixed-pitch families accepted by the terminal.
    public var fontFamilies: [String] { Self.installedFontFamilies }
    /// System sound names, without filename extensions.
    public var sounds: [String] { Self.installedSounds }

    /// Installed fixed-pitch families the terminal accepts, sorted.
    private static let installedFontFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: NSFont.systemFontSize)?.familyName })
            .filter { TerminalFontSetting().isValidFamily($0) && !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// The sounds in /System/Library/Sounds.
    private static let installedSounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()
}
