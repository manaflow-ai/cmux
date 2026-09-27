import CmuxFoundation
import Foundation

/// What the Settings terminal theme gallery needs from the host: where themes
/// live, which config file holds the managed `# cmux themes` block, and the
/// theme currently in effect.
public struct TerminalThemeGalleryContext: Sendable {
    /// The cmux Ghostty config file the gallery writes, shared with `cmux themes`.
    public let configFile: CmuxManagedThemeConfigFile
    /// Directories searched for theme files. Earlier directories win on a name clash.
    public let themeDirectories: [URL]
    /// The last `theme = ...` value across the loaded Ghostty config files.
    public let currentThemeValue: String?
    /// Whether the app currently renders in dark appearance.
    public let prefersDarkAppearance: Bool

    public init(
        configFile: CmuxManagedThemeConfigFile,
        themeDirectories: [URL],
        currentThemeValue: String?,
        prefersDarkAppearance: Bool
    ) {
        self.configFile = configFile
        self.themeDirectories = themeDirectories
        self.currentThemeValue = currentThemeValue
        self.prefersDarkAppearance = prefersDarkAppearance
    }
}

/// How the host should reload terminals after the gallery rewrote the block.
public enum TerminalThemeReloadPhase: Sendable {
    /// A card was picked; rapid picks can coalesce into one reload.
    case preview
    /// The previous config was restored; reload now.
    case final
}
